import 'dart:async';
import 'dart:math' show pow;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_theme.dart';
import '../screens/camera_fullscreen_screen.dart';
import '../services/dance_rumble.dart';
import '../services/dance_songs.dart';
import '../widgets/camera_filters.dart';
import '../models/node_link.dart';
import 'app_state.dart';
import 'assistant_state.dart';
import 'auto_route.dart';
import 'bot_link.dart';

/// Una acción del mando, para la bitácora de la pantalla "Mando".
class GamepadAction {
  final DateTime time;
  final String text;
  GamepadAction(this.text) : time = DateTime.now();
}

/// Ajustes del mando (se guardan en el teléfono).
class GamepadSettings {
  bool enabled = true;
  // La velocidad del stick de manejo ya no vive aquí: es la MISMA de la app
  // (AppState.speed, slider VELOCIDAD de la consola). L2+L3 / L2+R3 la cambian.
  int deadzone = 14; // % zona muerta de los sticks (5-30)
  int armSpeed = 4; // % por paso del brazo con el stick derecho (1-8)
  bool invertArmY = false;
  bool rumble = true;
  bool combos = true;
  String light = 'fire'; // fire = fuego rojo · mode = rojo fijo por modo · off · c:RRGGBB = fuego de ese color
  bool danceRumble = true; // vibrar (y destellar) al ritmo de los bailes
  bool gasLight = true; // en EXPLORACIÓN la luz sigue al MQ-2: verde / amarillo / rojo
  bool sportDuo = true; // en SPORT la luz alterna azul y rojo (patrulla)

  static const _p = 'gp_';

  Future<void> load() async {
    try {
      final s = await SharedPreferences.getInstance();
      enabled = s.getBool('gamepad_enabled') ?? enabled;
      deadzone = s.getInt('${_p}dz') ?? deadzone;
      armSpeed = s.getInt('${_p}arm') ?? armSpeed;
      invertArmY = s.getBool('${_p}invy') ?? invertArmY;
      rumble = s.getBool('${_p}rumble') ?? rumble;
      combos = s.getBool('${_p}combos') ?? combos;
      light = s.getString('${_p}light2') ?? light;
      danceRumble = s.getBool('${_p}drumble') ?? danceRumble;
      gasLight = s.getBool('${_p}gaslight') ?? gasLight;
      sportDuo = s.getBool('${_p}sportduo') ?? sportDuo;
    } catch (_) {}
  }

  Future<void> save() async {
    try {
      final s = await SharedPreferences.getInstance();
      await s.setBool('gamepad_enabled', enabled);
      await s.setInt('${_p}dz', deadzone);
      await s.setInt('${_p}arm', armSpeed);
      await s.setBool('${_p}invy', invertArmY);
      await s.setBool('${_p}rumble', rumble);
      await s.setBool('${_p}combos', combos);
      await s.setString('${_p}light2', light);
      await s.setBool('${_p}drumble', danceRumble);
      await s.setBool('${_p}gaslight', gasLight);
      await s.setBool('${_p}sportduo', sportDuo);
    } catch (_) {}
  }
}

/// Mando de PS4 (o cualquier gamepad) para TODA la app.
///
/// Funciona por dos caminos con el MISMO esquema de botones:
///   1. Mando conectado al TELÉFONO (Bluetooth/USB): lo lee MainActivity.kt
///      y llega aquí directo.
///   2. Mando conectado a la ESP32 de SENSORES (Bluepad32): esa placa hace
///      lo que es del carrito (manejo, modos, bailes, LEDs) y las acciones
///      que solo puede hacer la app (foto, pantalla completa, cámara, filtro,
///      IA, posiciones del brazo, paro) se las pide a CONTROL como "app_*";
///      la app las recoge de /estado y las ejecuta aquí en [runAction].
///
/// Es un EXTRA: no cambia nada de la app; sin mando todo sigue igual.
class GamepadLink extends ChangeNotifier {
  final AppState appState;
  final BotLink botLink;
  final AssistantState assistant;
  final AutoRoute autoRoute;
  final GlobalKey<NavigatorState> navigatorKey;
  GamepadLink({required this.appState, required this.botLink, required this.assistant, required this.autoRoute, required this.navigatorKey});

  static const _events = EventChannel('shadowbot/gamepad/events');
  static const _methods = MethodChannel('shadowbot/gamepad');

  // ---------------- Tabla de botones (la muestra la pantalla "Mando") ----------------
  static const mapAlways = [
    ('Stick izq.', 'Manejar (analógico)'),
    ('Stick der.', 'Mover el brazo / cámara'),
    ('Share', 'Tomar FOTO de la cámara principal'),
    ('L2 + Share', 'GRABAR / DETENER video (principal o las 2 cámaras)'),
    ('Options', 'Entrar / salir de PANTALLA COMPLETA'),
    ('R3', 'Centrar brazo'),
    ('L3', 'Escaneo panorámico con el brazo'),
    ('2x R1', 'Entrar al modo que se ve en el carrusel'),
    ('2x R2', 'GIRO de 360° sobre su eje (otra vez = cancelar)'),
    ('2x L2 (toques)', 'Salir al menú'),
    ('PS', 'PARO DE EMERGENCIA (siempre)'),
  ];

  static const mapCombos = [
    ('L2 + R1', 'Cambiar cámara principal CAM 1 ↔ CAM 2'),
    ('L2 + ✕', 'Faros (los 4 LEDs)'),
    ('L2 + ○', 'Retroceso corto'),
    ('L2 + □', 'Siguiente filtro de cámara (Normal → IR → B/N → Verde)'),
    ('L2 + △', 'Analizar la cámara con IA'),
    ('L2 + ↑ / → / ↓', 'Brazo a la posición A / B / C (vacía = la guarda)'),
    ('L2 + ←', 'Centrar brazo'),
    ('L2 + R2', 'Siguiente sección de la app'),
    ('L2 + Options', 'Prender / apagar la luz del LCD'),
    ('L2 + L3 / R3', 'Bajar / subir la velocidad del carrito (la misma de la app, de 10 en 10 %)'),
    ('↑↑↓↓←→←→ ○ ✕', 'En el MENÚ: modo FIESTA (DANCE + Everybody)'),
  ];

  static const mapByMode = {
    'menu': [
      ('← / →', 'Cambiar de página del carrusel'),
      ('✕', 'Entrar al modo que se ve'),
      ('○ □ △', 'LED 2, 3, 4'),
      ('Stick izq.', 'El carrito también se maneja en el menú'),
    ],
    'sport': [
      ('✕ ○ □ △', 'LED 1, 2, 3, 4'),
      ('', 'Velocidad máxima, como carrito RC'),
    ],
    'exploracion': [
      ('✕ ○ □ △', 'LED 1, 2, 3, 4'),
      ('↑ / ↓', 'Subir / bajar velocidad (20-100%)'),
      ('← / →', 'Cámara mira a la izquierda / derecha'),
      ('R2 mantenido', 'Modo preciso (35% de velocidad)'),
    ],
    'juego': [
      ('✕ ○ □ △', 'Bailes GIRO LOCO · ZIGZAG · SÍ Y NO · TWIST'),
      ('←', 'Everybody (música en el teléfono)'),
      ('→', 'Tokyo Drift (música en el teléfono)'),
      ('↓', 'Parar baile'),
    ],
  };

  static const _sections = [
    ScreenNames.control,
    ScreenNames.camara,
    ScreenNames.sensores,
    ScreenNames.galeria,
    ScreenNames.nodos,
    ScreenNames.mando,
    ScreenNames.alertas,
    ScreenNames.sistema,
  ];

  StreamSubscription? _sub;
  Timer? _tick;
  Timer? _armTick;
  Timer? _danceTimer;
  Timer? _notifyTimer;
  bool _dirty = false;

  final settings = GamepadSettings();
  bool connected = false;
  String? name;
  bool lightSupported = true;
  bool get enabled => settings.enabled;

  // Estado en vivo (para la pantalla de prueba).
  double lx = 0, ly = 0, rx = 0, ry = 0, lt = 0, rt = 0;
  final Set<String> held = {};
  int driveL = 0, driveR = 0;
  final List<GamepadAction> log = [];

  bool _l2FromKeys = false, _r2FromKeys = false;
  bool _wasDriving = false;
  bool _sendingMove = false;
  int _retreatUntil = 0;
  int _lastR1 = 0, _lastL2 = 0, _lastR2 = 0;
  int _lastLockedMsg = 0;
  String? _lastMode;
  int _l2DownAt = 0;
  bool _l2Combo = false;
  final List<String> _seq = [];
  int _fiestaUntil = 0;

  static const _doublePressMs = 400;
  static const _konami = ['UP', 'UP', 'DOWN', 'DOWN', 'LEFT', 'RIGHT', 'LEFT', 'RIGHT', 'B', 'A'];

  // ---------------- Ciclo de vida ----------------

  Future<void> start() async {
    await settings.load();
    botLink.onAppEvent = (ev) => runAction(ev, fromEsp: true);
    botLink.addListener(_onBotChanged);
    appState.addListener(_onGasChanged);
    if (kIsWeb) return; // el canal nativo solo existe en Android
    _sub = _events.receiveBroadcastStream().listen(_onEvent, onError: (_) {});
    _tick = Timer.periodic(const Duration(milliseconds: 100), (_) => _drive());
    _armTick = Timer.periodic(const Duration(milliseconds: _armDtMs), (_) => _arm());
    _notifyTimer = Timer.periodic(const Duration(milliseconds: 60), (_) {
      if (_dirty) {
        _dirty = false;
        notifyListeners();
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _tick?.cancel();
    _armTick?.cancel();
    _danceTimer?.cancel();
    _notifyTimer?.cancel();
    botLink.removeListener(_onBotChanged);
    appState.removeListener(_onGasChanged);
    botLink.onAppEvent = null;
    super.dispose();
  }

  /// Cambia un ajuste y lo guarda.
  Future<void> update(void Function(GamepadSettings s) change) async {
    change(settings);
    if (!settings.enabled) _stopDriving();
    _applyLight();
    notifyListeners();
    await settings.save();
  }

  Future<void> setEnabled(bool v) async {
    await update((s) => s.enabled = v);
    _log(v ? 'Mando habilitado' : 'Mando deshabilitado');
  }

  // ---------------- Eventos nativos ----------------

  void _onEvent(dynamic e) {
    if (e is! Map) return;
    switch (e['t']) {
      case 'conn':
        final c = e['connected'] == true;
        final n = e['name'] as String?;
        if (c != connected) {
          connected = c;
          name = n;
          if (c) {
            _log('Mando conectado: ${n ?? 'gamepad'}');
            _lastMode = null;
            _flash(255, 40, 30, 350);
            _applyLight();
            rumble(220, 180);
          } else {
            _log('Mando desconectado');
            _stopDriving();
            held.clear();
            lx = ly = rx = ry = lt = rt = 0;
          }
          notifyListeners();
        } else {
          name = n ?? name;
        }
      case 'axes':
        lx = (e['lx'] as num).toDouble();
        ly = (e['ly'] as num).toDouble();
        rx = (e['rx'] as num).toDouble();
        ry = (e['ry'] as num).toDouble();
        final nlt = (e['lt'] as num).toDouble();
        final nrt = (e['rt'] as num).toDouble();
        if (!_l2FromKeys) _edge('L2', lt, nlt);
        if (!_r2FromKeys) _edge('R2', rt, nrt);
        lt = nlt;
        rt = nrt;
        final hx = (e['hx'] as num).toDouble();
        final hy = (e['hy'] as num).toDouble();
        _hat('LEFT', hx < -0.5);
        _hat('RIGHT', hx > 0.5);
        _hat('UP', hy < -0.5);
        _hat('DOWN', hy > 0.5);
        _dirty = true;
      case 'btn':
        final k = e['k'] as String;
        if (k == 'L2') _l2FromKeys = true;
        if (k == 'R2') _r2FromKeys = true;
        _button(k, e['down'] == true);
    }
  }

  void _edge(String k, double before, double now) {
    if (before < 0.6 && now >= 0.6) _button(k, true);
    if (before >= 0.6 && now < 0.6) _button(k, false);
  }

  void _hat(String k, bool pressed) {
    if (pressed == held.contains(k)) return;
    _button(k, pressed);
  }

  // ---------------- Botones ----------------

  void _button(String k, bool down) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (down) {
      held.add(k);
    } else {
      held.remove(k);
    }
    _dirty = true;
    if (!settings.enabled) return;

    // L1 no se usa.
    if (k == 'L1') return;

    // L2 es "shift": mantenido + botón = combo. Dos toques cortos de L2 sin
    // combo de por medio = salir al menú (se cuenta al SOLTAR, para que un
    // combo nunca dispare la salida).
    if (k == 'L2') {
      if (down) {
        _l2DownAt = now;
        _l2Combo = false;
      } else if (!_l2Combo && now - _l2DownAt < 350 && !_lockedMsg(now)) {
        if (_double(now, isR1: false)) _pad('l2x2', '2x L2 → salir al menú');
      } else if (_l2Combo) {
        _lastL2 = 0;
      }
      return;
    }
    if (!down) return;

    if (k == 'PS') {
      runAction('paro');
      return;
    }
    if (_lockedMsg(now)) return;

    if (held.contains('L2') && settings.combos) {
      _l2Combo = true;
      _combo(k);
      return;
    }

    final mode = botLink.botMode;
    if (mode == 'menu' && settings.combos && _konamiStep(k)) return;

    // ---- Globales ----
    switch (k) {
      case 'SHARE':
        runAction('foto');
        return;
      case 'OPTIONS':
        runAction('full');
        return;
      case 'R3':
        runAction('centro');
        return;
      case 'L3':
        appState.armScan();
        _log('L3 → escaneo panorámico');
        return;
      case 'R1':
        if (_double(now, isR1: true)) _pad('r1x2', '2x R1 → entrar al modo');
        return;
      case 'R2':
        // R2 mantenido sigue siendo el modo preciso de EXPLORACIÓN.
        if (now - _lastR2 <= _doublePressMs) {
          _lastR2 = 0;
          runAction('giro');
        } else {
          _lastR2 = now;
        }
        return;
    }

    // ---- Botones de cara ----
    const face = ['A', 'B', 'X', 'Y'];
    const faceSym = ['✕', '○', '□', '△'];
    const danceNames = ['GIRO LOCO', 'ZIGZAG', 'SÍ Y NO', 'TWIST'];
    final fi = face.indexOf(k);
    if (fi >= 0) {
      if (mode == 'juego') {
        _pad('baile${fi + 1}', '${faceSym[fi]} → baile ${danceNames[fi]}');
      } else if (mode == 'menu' && k == 'A') {
        _pad('r1x2', '✕ → entrar al modo');
      } else {
        appState.toggleLed(fi + 1);
        _log('${faceSym[fi]} → LED ${fi + 1}');
      }
      return;
    }

    // ---- Cruceta según el modo ----
    switch (mode) {
      case 'menu':
        if (k == 'LEFT') _pad('swipe_l', '← página anterior');
        if (k == 'RIGHT') _pad('swipe_r', '→ página siguiente');
      case 'juego':
        if (k == 'LEFT') _pad('baile5', '← Everybody (con música)');
        if (k == 'RIGHT') _pad('baile6', '→ Tokyo Drift (con música)');
        if (k == 'DOWN') _pad('baile_stop', '↓ parar baile');
      case 'exploracion':
        if (k == 'UP') _pad('vel_up', '↑ más velocidad');
        if (k == 'DOWN') _pad('vel_down', '↓ menos velocidad');
        if (k == 'LEFT') {
          appState.scanning = false;
          appState.setArmAngles(11, appState.armTilt);
          _log('← cámara a la izquierda');
        }
        if (k == 'RIGHT') {
          appState.scanning = false;
          appState.setArmAngles(89, appState.armTilt);
          _log('→ cámara a la derecha');
        }
    }
  }

  void _combo(String k) {
    switch (k) {
      case 'A':
        runAction('faros');
      case 'B':
        runAction('retro');
      case 'X':
        runAction('filtro');
      case 'Y':
        runAction('ia');
      case 'UP':
        runAction('pa');
      case 'RIGHT':
        runAction('pb');
      case 'DOWN':
        runAction('pc');
      case 'LEFT':
        runAction('centro');
      case 'R1':
        runAction('cam');
      case 'R2':
        runAction('sec_sig');
      case 'OPTIONS':
        runAction('lcd');
      case 'SHARE':
        runAction('video');
      case 'L3':
        runAction('vel_menos');
      case 'R3':
        runAction('vel_mas');
    }
  }

  bool _lockedMsg(int now) {
    if (!appState.controlLocked) return false;
    if (now - _lastLockedMsg > 3000) {
      _lastLockedMsg = now;
      _log('Bloqueado — presiona INICIAR en Conexiones');
      rumble(120, 90);
    }
    return true;
  }

  bool _double(int now, {required bool isR1}) {
    final last = isR1 ? _lastR1 : _lastL2;
    final hit = last != 0 && now - last <= _doublePressMs;
    if (isR1) {
      _lastR1 = hit ? 0 : now;
    } else {
      _lastL2 = hit ? 0 : now;
    }
    return hit;
  }

  /// Avanza el código ↑↑↓↓←→←→○✕. Devuelve true si este botón lo completó.
  bool _konamiStep(String k) {
    _seq.add(k);
    if (_seq.length > _konami.length) _seq.removeAt(0);
    if (_seq.length == _konami.length && List.generate(_konami.length, (i) => _seq[i] == _konami[i]).every((v) => v)) {
      _seq.clear();
      runAction('fiesta');
      return true;
    }
    return false;
  }

  void _pad(String ev, String text) {
    _log(text);
    botLink.pad(ev);
  }

  // ---------------- Acciones (mando del teléfono y mando de la ESP32) ----------------

  /// Ejecuta una acción de la app. [fromEsp] = la pidió el mando conectado a
  /// la ESP32 (llegó por /estado); solo cambia el texto de la bitácora.
  void runAction(String a, {bool fromEsp = false}) {
    void note(String t) => _log(fromEsp ? 'Mando (ESP32): $t' : t);
    if (a != 'paro' && appState.controlLocked) {
      note('Bloqueado — presiona INICIAR');
      return;
    }
    switch (a) {
      case 'paro':
        _retreatUntil = 0;
        _fiestaUntil = 0;
        appState.emergencyStop();
        if (!fromEsp) _sendMove(0, 0, force: true);
        if (botLink.playing != null || botLink.starting != null || (botLink.estado?.baile ?? 0) != 0) botLink.stopFromApp();
        note('PS → PARO DE EMERGENCIA');
        _flash(255, 30, 20, 700);
        rumble(450, 255);
      case 'foto':
        note('Share → foto ${appState.primaryCamera == AiCameraSource.tapoCam ? 'CAM 2' : 'CAM 1'}');
        _flash(255, 255, 255, 140);
        rumble(60, 120);
        appState.takePhoto();
      case 'video':
        final stopping = appState.videoRecording;
        note(stopping ? 'L2+Share → detener video' : 'L2+Share → grabar ${appState.recordBoth ? 'CAM 1 + CAM 2' : 'video'}');
        _flash(255, 0, 0, stopping ? 200 : 500);
        rumble(stopping ? 90 : 220, stopping ? 120 : 200);
        appState.toggleRecording().then((msg) => _log(msg));
      case 'giro':
        note(autoRoute.spinning ? '2x R2 → cancelar giro' : '2x R2 → giro de 360°');
        rumble(160, 170);
        autoRoute.spin360().then((msg) => _log(msg));
      case 'full':
        note(appState.fullscreenOpen ? 'Options → salir de pantalla completa' : 'Options → pantalla completa');
        _toggleFullscreen();
      case 'cam':
        final next = appState.primaryCamera == AiCameraSource.tapoCam ? AiCameraSource.esp32cam : AiCameraSource.tapoCam;
        appState.setPrimaryCamera(next);
        note('L2+R1 → cámara principal ${next == AiCameraSource.tapoCam ? 'CAM 2' : 'CAM 1'}');
      case 'filtro':
        final cam = appState.primaryCamera;
        const order = CameraFilterMode.values;
        final next = order[(order.indexOf(appState.filterOf(cam)) + 1) % order.length];
        appState.setFilter(cam, next);
        note('L2+□ → filtro ${next.label}');
      case 'ia':
        if (!assistant.isBusy) {
          appState.setAiCameraSource(appState.primaryCamera);
          assistant.analyzeCurrentFrame();
        }
        note('L2+△ → análisis con IA');
      case 'faros':
        final all = appState.ledOn.every((v) => v);
        appState.setAllLeds(!all);
        note('L2+✕ → faros ${all ? 'apagados' : 'encendidos'}');
      case 'lcd':
        if (botLink.lcdLuz == null) {
          note('L2+Options → CONTROL sin LCD');
        } else {
          final on = !botLink.lcdLuz!;
          botLink.toggleLcdLight();
          note('L2+Options → luz del LCD ${on ? 'encendida' : 'apagada'}');
          rumble(60, 100);
        }
      case 'retro':
        if (fromEsp) {
          appState.shortRetreat();
        } else {
          _retreatUntil = DateTime.now().millisecondsSinceEpoch + 600;
        }
        note('L2+○ → retroceso corto');
      case 'vel_menos' || 'vel_mas':
        // La misma velocidad que el slider de la app (redondeada a decenas).
        final base = (appState.speed / 10).round() * 10;
        final v = (base + (a == 'vel_mas' ? 10 : -10)).clamp(10, 100);
        appState.setSpeed(v);
        rumble(60 + v, 60 + v * 19 ~/ 10); // más fuerte = más rápido
        note('L2+${a == 'vel_mas' ? 'R3' : 'L3'} → velocidad del carrito $v %');
      case 'centro':
        appState.scanning = false;
        appState.centerArm();
        note('Centrar brazo');
      case 'pa' || 'pb' || 'pc':
        final i = const ['pa', 'pb', 'pc'].indexOf(a);
        final label = const ['A', 'B', 'C'][i];
        if (appState.armPresets[i] == null) {
          appState.saveArmPreset(i);
          note('Posición $label guardada');
        } else {
          appState.recallArmPreset(i);
          note('Brazo a posición $label');
        }
      case 'sec_sig' || 'sec_ant':
        if (appState.fullscreenOpen) _toggleFullscreen();
        final cur = _sections.indexOf(appState.currentScreen);
        final step = a == 'sec_sig' ? 1 : -1;
        final next = _sections[((cur < 0 ? 0 : cur) + step + _sections.length) % _sections.length];
        appState.showScreen(next);
        note('Sección: $next');
      case 'fiesta':
        note('¡MODO FIESTA!');
        _fiestaUntil = DateTime.now().millisecondsSinceEpoch + 22000;
        _applyLight();
        rumble(500, 255);
        botLink.setMode('juego');
        Future.delayed(const Duration(milliseconds: 900), () => botLink.startFromApp(danceSongs.first));
        Future.delayed(const Duration(milliseconds: 22100), _applyLight);
    }
  }

  void _toggleFullscreen() {
    final nav = navigatorKey.currentState;
    if (nav == null) return;
    if (appState.fullscreenOpen) {
      nav.maybePop();
    } else {
      final ctx = navigatorKey.currentContext;
      if (ctx != null) openCameraFullscreen(ctx, appState.primaryCamera);
    }
  }

  // ---------------- Manejo y brazo (cada 100 ms) ----------------

  double _dz(double v) => v.abs() < settings.deadzone / 100 ? 0 : v;

  void _drive() {
    if (!connected || !settings.enabled || appState.controlLocked) {
      if (_wasDriving) _stopDriving();
      return;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final explora = botLink.botMode == 'exploracion';

    // ---- Motores: mezcla "arcade" (acelerar + girar), como en SENSORES.ino ----
    // Tope = la velocidad de la app (slider VELOCIDAD), igual que la consola.
    // CONTROL le aplica a /movevec el % del modo (EXPLORACIÓN = su velocidad,
    // JUEGO = 70); se compensa para que el carrito vaya a la velocidad de la
    // app y no al 100 % (en EXPLORACIÓN nunca pasa de su propia velocidad).
    final control = appState.controlService;
    final maxPwm = 255 * appState.speed ~/ 100 * 100 ~/ control.vecScale;
    var throttle = (-_dz(ly) * maxPwm).round();
    var steer = (_dz(lx) * maxPwm).round();
    if (explora && rt >= 0.5) {
      throttle = throttle * 35 ~/ 100; // R2 mantenido: modo preciso
      steer = steer * 35 ~/ 100;
    }
    var left = (throttle + steer).clamp(-255, 255);
    var right = (throttle - steer).clamp(-255, 255);
    if (now < _retreatUntil) {
      left = -160;
      right = -160;
    }
    final active = left != 0 || right != 0;
    if (active || _wasDriving) {
      // Mientras se empuja se manda siempre (alimenta el watchdog de 800 ms);
      // al soltar se manda un 0 y se deja de mandar.
      _sendMove(left, right);
      _wasDriving = active;
    }
  }

  // ---- Brazo: stick derecho como torreta, SUAVE ----
  // Antes: saltos de 1-8 % cada 100 ms (se sentía a tirones). Ahora el
  // stick fija una VELOCIDAD objetivo; la velocidad real sube y baja con
  // aceleración limitada (arranca y frena suave, aunque sueltes de golpe) y
  // la posición se lleva en grados con decimales, cada 40 ms.
  static const _armDtMs = 40;
  double _armPanDeg = 90, _armTiltDeg = 90, _armVx = 0, _armVy = 0;
  bool _armMoving = false;

  void _arm() {
    if (!connected || !settings.enabled || appState.controlLocked) {
      _armVx = _armVy = 0;
      _armMoving = false;
      return;
    }
    final ax = _dz(rx);
    final ay = _dz(ry) * (settings.invertArmY ? -1 : 1);
    if (!_armMoving && ax == 0 && ay == 0) return;
    if (!_armMoving) {
      // Arranca desde donde esté el brazo (pudo moverlo la app, un preset…).
      _armPanDeg = appState.armPan * 1.8;
      _armTiltDeg = appState.armTilt * 1.8;
      appState.scanning = false;
      _armMoving = true;
    }
    const dt = _armDtMs / 1000;
    final vmax = settings.armSpeed * 18.0; // °/s  (4 → 72 °/s, como antes)
    final acel = vmax * 5; //                    llega a tope en 0.2 s
    double curva(double v) => v.sign * pow(v.abs(), 1.6).toDouble(); // fino cerca del centro
    double hacia(double v, double objetivo) => v + (objetivo - v).clamp(-acel * dt, acel * dt);
    _armVx = hacia(_armVx, curva(ax) * vmax);
    _armVy = hacia(_armVy, -curva(ay) * vmax);
    _armPanDeg = (_armPanDeg + _armVx * dt).clamp(0, 180);
    _armTiltDeg = (_armTiltDeg + _armVy * dt).clamp(0, 180);
    if (_armPanDeg <= 0 || _armPanDeg >= 180) _armVx = 0;
    if (_armTiltDeg <= 0 || _armTiltDeg >= 180) _armVy = 0;
    appState.setArmDegreesFromPad(_armPanDeg, _armTiltDeg);
    if (ax == 0 && ay == 0 && _armVx.abs() < 1 && _armVy.abs() < 1) {
      _armVx = _armVy = 0;
      _armMoving = false;
    }
  }

  // ---------------- Vibración al ritmo del baile ----------------
  // Mientras el carrito baila (lo diga /estado, se haya lanzado desde la app
  // o desde el mando) el mando golpea en cada paso de la coreografía, y en
  // los pasos largos a cada tiempo de la canción. La barra de luz destella
  // con el golpe.
  int _danceKey = -1;
  static const _danceColors = [(40, 255, 90), (190, 255, 0), (0, 200, 255), (255, 40, 200)];

  void _syncDance() {
    final want = connected && settings.danceRumble && botLink.estado != null && botLink.danceNum > 0 && botLink.danceMotorsStartAt != null;
    if (want && _danceTimer == null) {
      _danceKey = -1;
      _danceTimer = Timer.periodic(const Duration(milliseconds: 15), (_) => _danceBeat());
    } else if (!want && _danceTimer != null) {
      _danceTimer!.cancel();
      _danceTimer = null;
      _applyLight();
    }
  }

  void _danceBeat() {
    final start = botLink.danceMotorsStartAt;
    final r = danceRumbles[botLink.danceNum];
    if (start == null || r == null) return;
    final pos = r.at(DateTime.now().difference(start).inMilliseconds);
    if (pos == null) return;
    final key = pos.step * 1000 + pos.sub;
    if (key == _danceKey) return;
    _danceKey = key;
    final amp = pos.sub > 0 ? pos.s.amp * 65 ~/ 100 : pos.s.amp;
    if (amp <= 0) return;
    final ms = (pos.s.ms * 0.45).clamp(60, 150).round();
    _invoke('rumble', {'ms': ms, 'amp': amp});
    if (settings.light != 'off') {
      final (cr, cg, cb) = _danceColors[key % _danceColors.length];
      _flash(cr, cg, cb, ms + 40);
    }
  }

  void _sendMove(int l, int r, {bool force = false}) {
    driveL = l;
    driveR = r;
    _dirty = true;
    if (_sendingMove && !force) return;
    _sendingMove = true;
    appState.controlService.sendMoveVec(l, r).whenComplete(() => _sendingMove = false);
  }

  void _stopDriving() {
    _wasDriving = false;
    _retreatUntil = 0;
    _sendMove(0, 0, force: true);
  }

  // ---------------- Barra de luz (fuego rojo) / vibración ----------------

  void _onBotChanged() {
    _syncDance();
    final m = botLink.botMode;
    if (!connected || m == _lastMode) return;
    final entering = _lastMode != null && (m == 'sport' || m == 'exploracion' || m == 'juego');
    _lastMode = m;
    if (entering) {
      _flash(255, 110, 80, 220);
      rumble(180, 160);
    }
    _applyLight();
    if (m != null) _log('Modo: ${BotLink.modeLabel(m)}');
  }

  // ---------------- Luz según el gas (MQ-2) en EXPLORACIÓN ----------------
  // EXPLORACIÓN es el modo de inspección: con la placa de sensores en línea
  // (lectura real, no la de demostración) la barra de luz hace fuego verde,
  // amarillo o rojo según el nivel del MQ-2, y vibra al entrar a rojo.

  /// Límite entre verde y amarillo (% del MQ-2). Rojo = límite de alerta
  /// del sensor (`GasReading.limit`, el mismo de Alertas).
  static const gasYellowAt = 20.0;

  int? _gasBand; // 0 verde · 1 amarillo · 2 rojo · null = no aplica

  int? _currentGasBand() {
    if (!settings.gasLight || botLink.botMode != 'exploracion') return null;
    if (!appState.deviceConfig.of(HardwareNode.esp32Sensors).isOnline) return null;
    final g = appState.gasReadings['mq2']!;
    return g.value > g.limit ? 2 : (g.value >= gasYellowAt ? 1 : 0);
  }

  void _onGasChanged() {
    final b = _currentGasBand();
    if (b == _gasBand) return;
    final prev = _gasBand;
    _gasBand = b;
    if (!connected) return;
    if (b == 2 && prev != 2) rumble(500, 255);
    _applyLight();
    notifyListeners();
  }

  /// Color por defecto de la barra de luz: fuego ROJO.
  static const defaultFire = 0xFF0000;

  /// Fuego del color elegido (rojo por defecto, más vivo según el modo), rojo
  /// fijo por modo, azul + rojo en SPORT y semáforo del MQ-2 en EXPLORACIÓN.
  void _applyLight() {
    if (!connected) return;
    final fiesta = DateTime.now().millisecondsSinceEpoch < _fiestaUntil;
    final m = botLink.botMode;
    if (settings.light == 'off') {
      _invoke('lightMode', {'mode': 'off'});
      return;
    }
    _gasBand = _currentGasBand();
    final band = _gasBand;
    if (band != null && !fiesta) {
      final (r, g, b, heat, period) = switch (band) {
        2 => (255, 0, 0, 100, 30),
        1 => (255, 190, 0, 75, 55),
        _ => (0, 255, 60, 50, 85),
      };
      _invoke('lightMode', {'mode': 'fire', 'heat': heat, 'period': period, 'r': r, 'g': g, 'b': b});
      return;
    }
    if (m == 'sport' && settings.sportDuo && !fiesta) {
      // SPORT: fuego que alterna azul y rojo (patrulla).
      _invoke('lightMode', {'mode': 'duo', 'heat': 90, 'period': 45, 'r': 255, 'g': 0, 'b': 0, 'r2': 0, 'g2': 60, 'b2': 255});
      return;
    }
    if (settings.light == 'mode' && !fiesta) {
      final (r, g, b) = switch (m) {
        'sport' => (255, 0, 0),
        'exploracion' => (150, 0, 0),
        'juego' => (255, 40, 20),
        'menu' => (200, 0, 10),
        _ => (60, 0, 0),
      };
      _invoke('lightMode', {'mode': 'solid', 'r': r, 'g': g, 'b': b});
      return;
    }
    final (heat, period) = fiesta
        ? (100, 30)
        : switch (m) {
            'sport' => (90, 45),
            'exploracion' => (50, 85),
            'juego' => (100, 35),
            'menu' => (45, 90),
            _ => (30, 110),
          };
    final c = settings.light.startsWith('c:') ? int.tryParse(settings.light.substring(2), radix: 16) ?? defaultFire : defaultFire;
    _invoke('lightMode', {'mode': 'fire', 'heat': heat, 'period': period, 'r': (c >> 16) & 0xFF, 'g': (c >> 8) & 0xFF, 'b': c & 0xFF}).then((ok) {
      if (ok is bool && ok != lightSupported) {
        lightSupported = ok;
        notifyListeners();
      }
    });
  }

  void _flash(int r, int g, int b, int ms) => _invoke('flash', {'r': r, 'g': g, 'b': b, 'ms': ms});

  void rumble(int ms, int amp) {
    if (settings.rumble) _invoke('rumble', {'ms': ms, 'amp': amp});
  }

  /// Destello de prueba desde la pantalla "Mando".
  void testLight() {
    _flash(255, 50, 40, 400);
    Future.delayed(const Duration(milliseconds: 450), _applyLight);
  }

  Future<dynamic> _invoke(String method, Map<String, dynamic> args) async {
    if (kIsWeb) return null;
    try {
      return await _methods.invokeMethod(method, args);
    } catch (_) {
      return null;
    }
  }

  void _log(String text) {
    log.insert(0, GamepadAction(text));
    if (log.length > 14) log.removeLast();
    _dirty = true;
  }

  /// Color de acento para la UI según si está listo.
  Color get statusColor => !connected ? AppColors.text3 : (settings.enabled ? AppColors.olive : AppColors.yellow);
}
