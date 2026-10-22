import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/esp32_control_service.dart';
import 'bot_link.dart';

/// Un tramo de la ruta: lo que hizo cada rueda (-255..255, ya con la
/// velocidad real aplicada) y cuánto duró.
class RouteSegment {
  final int l, r;
  int ms;
  RouteSegment(this.l, this.r, this.ms);
}

enum AutoRouteState { idle, recording, returning }

/// Modo AUTÓNOMO de EXPLORACIÓN: "trazar ruta" y "regreso inteligente".
///
/// No hay sensor de recorrido: la ruta se graba con lo que la app le manda
/// a CONTROL (D-pad/joystick de la consola, mando, voz) y cuánto tiempo
/// duró cada orden. Al regresar, el bot se da media vuelta (con los
/// segundos por vuelta que el usuario midió en Ajustes) y repite los tramos
/// del último al primero con izquierda↔derecha intercambiadas: así, ya
/// volteado, deshace el camino tal como llegó.
///
/// Todo va por `/movevec` con la velocidad de EXPLORACIÓN puesta en 100%
/// mientras regresa (los tramos ya traen la velocidad real grabada), y al
/// terminar se deja la velocidad que tenía. No hace falta tocar el firmware.
class AutoRoute extends ChangeNotifier {
  final BotLink botLink;
  AutoRoute({required this.botLink}) {
    _control.onUserDrive = _onUserDrive;
    botLink.addListener(_onBotChanged);
    _load();
  }

  /// Al salir de EXPLORACIÓN se cierra AUTÓNOMO (y lo que estuviera haciendo).
  void _onBotChanged() {
    final m = botLink.botMode;
    if (autonomo && m != null && m != 'exploracion') setAutonomo(false);
  }

  Esp32ControlService get _control => botLink.appState.controlService;

  /// Watchdog del firmware: sin órdenes nuevas en 800 ms, frena solo.
  static const _watchdogMs = 800;

  /// Velocidad de EXPLORACIÓN a la que se mide "segundos por vuelta".
  static const calibVel = 60;

  /// Sub-modo AUTÓNOMO abierto dentro de EXPLORACIÓN (muestra los botones).
  bool autonomo = false;

  void setAutonomo(bool v) {
    if (!v) {
      cancelReturn();
      stopRecording();
    }
    autonomo = v;
    notifyListeners();
  }

  AutoRouteState state = AutoRouteState.idle;
  final List<RouteSegment> segments = [];

  /// 0..1 mientras regresa (para la barra de progreso).
  double progress = 0;
  String? lastMessage;

  bool get recording => state == AutoRouteState.recording;
  bool get returning => state == AutoRouteState.returning;
  bool get hasRoute => segments.isNotEmpty;

  /// Tiempo total en movimiento de la ruta grabada.
  int get routeMs => segments.fold(0, (a, s) => a + s.ms);

  // ---------------- Ajustes (se guardan en el teléfono) ----------------
  static const _keyTurnSecs = 'auto_turn_secs';
  static const _keyFinalTurn = 'auto_final_turn';

  /// Segundos que tarda en dar una vuelta COMPLETA (360°) sobre su eje a
  /// [calibVel]% — lo cronometra el usuario y lo pone en Ajustes.
  double turnSecs = 3.0;

  /// Al terminar el regreso, otra media vuelta para quedar mirando hacia
  /// donde miraba al empezar la ruta.
  bool finalTurn = false;

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    turnSecs = prefs.getDouble(_keyTurnSecs) ?? turnSecs;
    finalTurn = prefs.getBool(_keyFinalTurn) ?? finalTurn;
    notifyListeners();
  }

  Future<void> setTurnSecs(double v) async {
    turnSecs = double.parse(v.clamp(0.5, 20.0).toStringAsFixed(1));
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_keyTurnSecs, turnSecs);
  }

  Future<void> setFinalTurn(bool v) async {
    finalTurn = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyFinalTurn, v);
  }

  // ---------------- Grabación ----------------
  RouteSegment? _open; // tramo en curso
  DateTime? _openStart, _openLastSeen;

  void startRecording() {
    if (returning) return;
    segments.clear();
    _open = null;
    state = AutoRouteState.recording;
    lastMessage = 'Trazando ruta — maneja normal';
    notifyListeners();
  }

  void stopRecording() {
    if (!recording) return;
    _closeOpen(DateTime.now());
    state = AutoRouteState.idle;
    lastMessage = hasRoute ? 'Ruta guardada (${(routeMs / 1000).toStringAsFixed(1)} s en movimiento)' : 'No se grabó movimiento';
    notifyListeners();
  }

  void clearRoute() {
    if (returning) return;
    segments.clear();
    _open = null;
    if (recording) state = AutoRouteState.idle;
    lastMessage = null;
    notifyListeners();
  }

  /// Cada orden de manejo del usuario (ver `Esp32ControlService.onUserDrive`).
  /// `vec` = viene de /movevec (CONTROL le aplica la velocidad de EXPLORACIÓN);
  /// si no, de /move con su propio % (`speed`).
  void _onUserDrive(String? dir, int speed, int l, int r, bool vec) {
    if (spinning) cancelSpin(sendStop: false); // cualquier orden del usuario corta el giro
    if (!recording && !returning) return;
    int el, er;
    if (vec) {
      final vel = botLink.botMode == 'exploracion' ? (botLink.estado?.vel ?? 60) : 100;
      el = l * vel ~/ 100;
      er = r * vel ~/ 100;
    } else {
      (el, er) = Esp32ControlService.wheelsFor(dir ?? 'detener', speed);
    }
    if (returning) {
      // El usuario tomó el control (o pidió parar): se cancela el regreso.
      if (el == 0 && er == 0) {
        cancelReturn();
      } else {
        cancelReturn(byUser: true);
      }
      return;
    }
    final now = DateTime.now();
    final o = _open;
    if (o != null && (o.l - el).abs() <= 6 && (o.r - er).abs() <= 6) {
      _openLastSeen = now; // misma orden repetida: sigue el mismo tramo
      return;
    }
    _closeOpen(now);
    if (el != 0 || er != 0) {
      _open = RouteSegment(el, er, 0);
      _openStart = now;
      _openLastSeen = now;
    }
  }

  void _closeOpen(DateTime now) {
    final o = _open;
    if (o == null) return;
    // Si dejaron de llegar órdenes, CONTROL frenó a los 800 ms de la última.
    final end = now.isBefore(_openLastSeen!.add(const Duration(milliseconds: _watchdogMs)))
        ? now
        : _openLastSeen!.add(const Duration(milliseconds: _watchdogMs));
    o.ms = end.difference(_openStart!).inMilliseconds;
    if (o.ms >= 40) {
      segments.add(o);
      notifyListeners();
    }
    _open = null;
  }

  // ---------------- Regreso inteligente ----------------
  int _gen = 0;
  int _prevVel = 60; // velocidad de EXPLORACIÓN antes de regresar

  Future<void> startReturn() async {
    if (recording) stopRecording();
    if (returning || !hasRoute) return;
    final gen = ++_gen;
    state = AutoRouteState.returning;
    progress = 0;
    lastMessage = 'Regreso inteligente en curso';
    notifyListeners();

    _prevVel = botLink.estado?.vel ?? 60;
    await botLink.setExploraVel(100);
    var ok = true;
    try {
      final route = List<RouteSegment>.of(segments.reversed);
      final halfTurn = (turnSecs * 500).round();
      final total = halfTurn * (finalTurn ? 2 : 1) + route.fold(0, (a, s) => a + s.ms);
      var done = 0;
      void tick(int ms) {
        done += ms;
        progress = total == 0 ? 1 : (done / total).clamp(0, 1);
        notifyListeners();
      }

      ok = await _turnHalf(gen) && await _pause(gen);
      tick(halfTurn);
      for (final s in route) {
        if (!ok) break;
        // Ya volteado, cada tramo se repite con los lados intercambiados.
        ok = await _drive(gen, s.r, s.l, s.ms);
        tick(s.ms);
      }
      if (ok && finalTurn) {
        ok = await _pause(gen) && await _turnHalf(gen);
        tick(halfTurn);
      }
    } finally {
      if (gen == _gen) {
        await _control.sendMoveVec(0, 0, auto: true);
        await botLink.setExploraVel(_prevVel);
        if (ok) {
          segments.clear();
          lastMessage = 'Regreso completado';
        }
        state = AutoRouteState.idle;
        notifyListeners();
      }
    }
  }

  void cancelReturn({bool byUser = false}) {
    if (!returning) return;
    _gen++;
    state = AutoRouteState.idle;
    lastMessage = byUser ? 'Regreso cancelado: tomaste el control' : 'Regreso detenido';
    if (!byUser) _control.sendMoveVec(0, 0, auto: true);
    botLink.setExploraVel(_prevVel);
    notifyListeners();
  }

  /// Media vuelta sobre su eje (a la derecha) a la velocidad de calibración.
  Future<bool> _turnHalf(int gen) {
    final v = (calibVel * 255 / 100).round();
    return _drive(gen, v, -v, (turnSecs * 500).round());
  }

  Future<bool> _pause(int gen) => _drive(gen, 0, 0, 300);

  /// Mantiene (l, r) durante [ms], repitiendo la orden antes del watchdog.
  Future<bool> _drive(int gen, int l, int r, int ms) async {
    final sw = Stopwatch()..start();
    while (sw.elapsedMilliseconds < ms) {
      if (gen != _gen) return false;
      if (botLink.estado != null && botLink.botMode != 'exploracion') {
        cancelReturn();
        return false;
      }
      unawaited(_control.sendMoveVec(l, r, auto: true));
      final left = ms - sw.elapsedMilliseconds;
      await Future.delayed(Duration(milliseconds: left < 200 ? (left > 0 ? left : 0) : 200));
    }
    return gen == _gen;
  }

  // ---------------- Prueba de calibración ----------------

  /// Da una vuelta completa con los segundos de Ajustes, para comprobar la
  /// medida (si se pasa o se queda corto, ajusta y repite).
  Future<String?> testTurn() async {
    if (returning || recording) return 'Termina la ruta antes de probar';
    if (botLink.botMode != 'exploracion') return 'Entra a EXPLORACIÓN para probar la vuelta';
    final gen = ++_gen;
    state = AutoRouteState.returning;
    progress = 0;
    lastMessage = 'Probando vuelta completa';
    notifyListeners();
    _prevVel = botLink.estado?.vel ?? 60;
    await botLink.setExploraVel(100);
    try {
      final v = (calibVel * 255 / 100).round();
      await _drive(gen, v, -v, (turnSecs * 1000).round());
    } finally {
      if (gen == _gen) {
        await _control.sendMoveVec(0, 0, auto: true);
        await botLink.setExploraVel(_prevVel);
        state = AutoRouteState.idle;
        lastMessage = null;
        notifyListeners();
      }
    }
    return null;
  }

  // ---------------- Giro de 360° sobre su eje ----------------
  // Botón GIRO 360° de la consola y 2x R2 en el mando. Usa los segundos por
  // vuelta de la calibración, en cualquier modo, y compensa lo que CONTROL
  // le aplica a /movevec según el modo para girar siempre al 60 %.

  bool spinning = false;
  int _spinGen = 0;

  /// Da una vuelta completa sobre su eje (a la derecha; [left] = a la
  /// izquierda). Si ya está girando, lo cancela. Devuelve un texto para el
  /// usuario.
  Future<String> spin360({bool left = false}) async {
    if (spinning) {
      cancelSpin();
      return 'Giro cancelado';
    }
    if (returning) return 'Espera a que termine el regreso inteligente';
    if (!_control.isConfigured) return 'CONTROL no vinculado — sin giro';
    final gen = ++_spinGen;
    spinning = true;
    notifyListeners();

    final explora = botLink.botMode == 'exploracion';
    final prevVel = botLink.estado?.vel ?? 60;
    final raiseVel = explora && prevVel < calibVel;
    if (raiseVel) await botLink.setExploraVel(100);
    final scale = raiseVel ? 100 : _control.vecScale;
    final v = (calibVel * 255 / scale).round().clamp(0, 255);
    final (l, r) = left ? (-v, v) : (v, -v);
    final ms = (turnSecs * 1000).round();
    final sw = Stopwatch()..start();
    try {
      while (sw.elapsedMilliseconds < ms && gen == _spinGen) {
        unawaited(_control.sendMoveVec(l, r, auto: true));
        final rest = ms - sw.elapsedMilliseconds;
        await Future.delayed(Duration(milliseconds: rest < 200 ? (rest > 0 ? rest : 0) : 200));
      }
    } finally {
      if (gen == _spinGen) {
        spinning = false;
        await _control.sendMoveVec(0, 0, auto: true);
      }
      if (raiseVel) await botLink.setExploraVel(prevVel);
      // Si se estaba trazando una ruta, el giro también cuenta como tramo.
      if (recording) {
        final now = DateTime.now();
        _closeOpen(now);
        final e = (calibVel * 255 / 100).round();
        segments.add(RouteSegment(left ? -e : e, left ? e : -e, sw.elapsedMilliseconds));
      }
      notifyListeners();
    }
    return gen == _spinGen ? 'Giro de 360° ${left ? 'a la izquierda' : 'a la derecha'} completo' : 'Giro cancelado';
  }

  void cancelSpin({bool sendStop = true}) {
    if (!spinning) return;
    _spinGen++;
    spinning = false;
    if (sendStop) _control.sendMoveVec(0, 0, auto: true);
    notifyListeners();
  }

  @override
  void dispose() {
    _gen++;
    _spinGen++;
    botLink.removeListener(_onBotChanged);
    if (_control.onUserDrive == _onUserDrive) _control.onUserDrive = null;
    super.dispose();
  }
}
