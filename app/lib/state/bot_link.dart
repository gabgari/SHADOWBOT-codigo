import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:media_kit/media_kit.dart';

import '../services/dance_songs.dart';
import '../services/esp32_control_service.dart';
import 'app_state.dart';

/// Enlace en vivo con la ESP32-S3 de CONTROL: modo del bot, telemetría de
/// la consola (ping, RSSI, potencia de cada motor) y la música de los bailes
/// con canción, para toda la app (suena aunque se esté en otra pantalla).
///
/// Tras "Iniciar" consulta `/estado` de CONTROL ~3 veces por segundo: así
/// sabe en qué modo está el bot ([botMode]) y, si un baile con canción se
/// lanzó desde el mando (modo DANCE, flechas ←/→), pone la música en la
/// bocina del celular. El firmware espera ~0.9 s antes de mover los motores
/// en esos bailes; la app usa ese margen para cargar el audio y arrancarlo
/// justo cuando arrancan los motores (o, si llegó tarde, salta al segundo en
/// que va el baile).
class BotLink extends ChangeNotifier {
  final AppState appState;
  BotLink({required this.appState});

  static const _pollEvery = Duration(milliseconds: 330);

  final Player _player = Player();
  String? _loadedAsset;
  Timer? _pollTimer;
  Timer? _endTimer;
  bool _polling = false;

  /// Modo actual del bot (off | menu | sport | exploracion | juego), o
  /// `null` si CONTROL no responde o la app aún no presiona "Iniciar".
  String? botMode;

  /// Última respuesta de /estado (null = sin conexión).
  BotEstado? estado;

  /// Ida y vuelta de la última consulta (ms) y las últimas 30, para la
  /// gráfica de PING de la consola.
  int? rttMs;
  final List<double> rttHistory = [];

  /// Baile en curso en el carrito (0 = ninguno) y el momento en que
  /// arrancaron (o arrancarán) sus motores, para que el mando vibre al
  /// ritmo de cada paso (ver GamepadLink y dance_rumble.dart).
  int danceNum = 0;
  DateTime? danceMotorsStartAt;
  int _danceSeqSeen = -1;

  /// Acciones que el mando conectado a la ESP32 le pide a la app (vía /estado).
  void Function(String ev)? onAppEvent;
  int _lastAseq = -1;

  int? playing; // número de baile sonando ahora
  int? starting; // número de baile que está arrancando
  int? _playingSeq; // seq (ver /estado) del baile que suena
  int _handledSeq = -1; // último seq que ya se atendió
  int _gen = 0; // invalida arranques a medias cuando algo cambia
  DateTime _lastLocalChange = DateTime.fromMillisecondsSinceEpoch(0);

  Esp32ControlService get _control => appState.controlService;

  /// Nombre del modo para mostrar (la pantalla redonda llama DANCE al modo "juego").
  static String modeLabel(String? m) => switch (m) {
        null => '—',
        'off' => 'ESPERA',
        'menu' => 'MENÚ',
        'sport' => 'SPORT',
        'exploracion' => 'EXPLORACIÓN',
        'juego' => 'DANCE',
        _ => m.toUpperCase(),
      };

  // ---------------- Mando virtual ----------------
  // Lo mismo que hace el DS4: elegir/entrar/salir de modos, velocidad de
  // exploración y bailes. Tras cada orden se vuelve a leer /estado enseguida
  // para que la app refleje el cambio sin esperar al siguiente sondeo.

  Future<bool> setMode(String mode) => _send(_control.setMode(mode));
  Future<bool> pad(String ev) => _send(_control.padEvent(ev));
  Future<bool> setExploraVel(int vel) => _send(_control.setExploraVel(vel.clamp(20, 100)));

  /// Luz de fondo del LCD 16x2 (null = firmware sin LCD).
  bool? get lcdLuz => estado?.lcdLuz;

  /// Prende/apaga la luz del LCD. Devuelve el estado nuevo (o null si
  /// CONTROL no responde).
  Future<bool?> toggleLcdLight() async {
    final on = !(lcdLuz ?? true);
    final ok = await _send(_control.setLcdLight(on));
    return ok ? on : null;
  }

  Future<bool> _send(Future<bool> f) async {
    final ok = await f;
    Future.delayed(const Duration(milliseconds: 60), _poll);
    return ok;
  }

  void start() {
    _pollTimer ??= Timer.periodic(_pollEvery, (_) => _poll());
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _endTimer?.cancel();
    _player.dispose();
    super.dispose();
  }

  // ---------------- Consulta de /estado ----------------

  Future<void> _poll() async {
    if (_polling) return;
    if (!appState.systemStarted || !_control.isConfigured) {
      if (estado != null) {
        estado = null;
        rttMs = null;
        notifyListeners();
      }
      _setMode(null);
      return;
    }
    _polling = true;
    final sentAt = DateTime.now();
    try {
      final e = await _control.getEstado();
      final receivedAt = DateTime.now();
      estado = e;
      if (e != null) {
        // Evento del mando conectado a la ESP32 (foto, pantalla completa…):
        // lo ejecuta GamepadLink, igual que si viniera del mando del teléfono.
        if (_lastAseq >= 0 && e.aseq != _lastAseq && e.aev.isNotEmpty) onAppEvent?.call(e.aev);
        _lastAseq = e.aseq;
        rttMs = receivedAt.difference(sentAt).inMilliseconds;
        _trackDance(e, receivedAt);
        rttHistory.add(rttMs!.toDouble());
        if (rttHistory.length > 30) rttHistory.removeAt(0);
      } else {
        rttMs = null;
        _lastAseq = -1;
      }
      notifyListeners();
      _setMode(e?.modo);
      // Una respuesta pedida antes de que la app arrancara/parara un baile
      // describe el estado viejo: se ignora.
      if (e == null || sentAt.isBefore(_lastLocalChange)) return;
      _handle(e, sentAt, receivedAt);
    } finally {
      _polling = false;
    }
  }

  void _trackDance(BotEstado e, DateTime receivedAt) {
    if (e.baile == 0) {
      danceNum = 0;
      danceMotorsStartAt = null;
      return;
    }
    final est = receivedAt.subtract(Duration(milliseconds: e.t + (rttMs ?? 0) ~/ 2));
    final prev = danceMotorsStartAt;
    if (e.seq != _danceSeqSeen || prev == null) {
      _danceSeqSeen = e.seq;
      danceMotorsStartAt = est;
    } else if ((est.difference(prev).inMilliseconds).abs() > 120) {
      // Se va afinando con cada consulta (la red no siempre tarda lo mismo).
      danceMotorsStartAt = prev.add(Duration(milliseconds: est.difference(prev).inMilliseconds ~/ 2));
    }
    danceNum = e.baile;
  }

  void _setMode(String? m) {
    if (m == botMode) return;
    botMode = m;
    notifyListeners();
  }

  void _handle(BotEstado e, DateTime sentAt, DateTime receivedAt) {
    // El baile que sonaba terminó o lo cortaron (↓ del mando, 2x L2, otro baile).
    if ((playing != null || starting != null) && _playingSeq != null && (e.baile == 0 || e.seq != _playingSeq)) {
      _stopLocal();
    }
    final song = _songFor(e.baile);
    if (song == null || e.seq == _handledSeq || e.seq == _playingSeq) return;
    _handledSeq = e.seq;
    // En el bot pasaron t ms al responder; la respuesta tardó ~media vuelta.
    final halfRtt = receivedAt.difference(sentAt).inMilliseconds ~/ 2;
    final motorsStartAt = receivedAt.subtract(Duration(milliseconds: e.t + halfRtt));
    _playSynced(song, e.seq, motorsStartAt);
  }

  DanceSong? _songFor(int n) {
    for (final s in danceSongs) {
      if (s.n == n) return s;
    }
    return null;
  }

  /// Baile lanzado desde el mando: pone la música alineada con el momento
  /// en que arrancan (o arrancaron) los motores.
  Future<void> _playSynced(DanceSong s, int seq, DateTime motorsStartAt) async {
    final gen = ++_gen;
    _endTimer?.cancel();
    await _player.pause();
    starting = s.n;
    playing = null;
    _playingSeq = seq;
    notifyListeners();

    final hasAudio = await _load(s);
    if (gen != _gen) return;

    var elapsed = DateTime.now().difference(motorsStartAt).inMilliseconds;
    final durMs = (s.durSec * 1000).round();
    if (elapsed >= durMs) {
      _clear();
      return;
    }
    if (hasAudio) {
      await _player.seek(Duration(milliseconds: (s.startSec * 1000).round() + (elapsed > 0 ? elapsed : 0)));
      if (gen != _gen) return;
      elapsed = DateTime.now().difference(motorsStartAt).inMilliseconds;
      if (elapsed < 0) await Future.delayed(Duration(milliseconds: -elapsed));
      if (gen != _gen) return;
      _player.play();
    }
    final remaining = durMs - DateTime.now().difference(motorsStartAt).inMilliseconds;
    _endTimer = Timer(Duration(milliseconds: remaining.clamp(0, durMs)), _finished);
    starting = null;
    playing = s.n;
    notifyListeners();
  }

  // ---------------- Bailes lanzados desde la app ----------------

  /// Arranca [s] desde la app (botón de la tarjeta Bailes). Devuelve un
  /// mensaje para el usuario si algo falló, o `null` si todo bien.
  Future<String?> startFromApp(DanceSong s) async {
    if (playing != null || starting != null) await stopFromApp();
    final gen = ++_gen;
    _lastLocalChange = DateTime.now();
    starting = s.n;
    notifyListeners();

    // Deja la canción cargada y en su segundo de inicio ANTES de avisarle al
    // carrito, para que al arrancar solo falte darle "play".
    final hasAudio = await _load(s);
    if (hasAudio) await _player.seek(Duration(milliseconds: (s.startSec * 1000).round()));
    if (gen != _gen) return null;

    // Música y baile al mismo tiempo.
    _lastLocalChange = DateTime.now();
    final danceFuture = _control.startDance(s.n);
    if (hasAudio) _player.play();
    final seq = await danceFuture;
    _lastLocalChange = DateTime.now();
    if (gen != _gen) return null;

    if (seq == null) {
      await _player.pause();
      _clear();
      return 'El carrito no respondió (¿sin conexión o ya está bailando?)';
    }
    _handledSeq = seq;
    _playingSeq = seq == 0 ? null : seq; // firmware viejo: sin seq, solo el temporizador
    _endTimer?.cancel();
    _endTimer = Timer(Duration(milliseconds: (s.durSec * 1000).round()), _finished);
    starting = null;
    playing = s.n;
    notifyListeners();
    return hasAudio ? null : 'Bailando sin música: falta ${s.asset}';
  }

  Future<void> stopFromApp() async {
    _lastLocalChange = DateTime.now();
    _stopLocal();
    await _control.stopDance();
    _lastLocalChange = DateTime.now();
  }

  // ---------------- Auxiliares ----------------

  Future<bool> _load(DanceSong s) async {
    if (_loadedAsset == s.asset) return true;
    try {
      await rootBundle.load(s.asset);
    } catch (_) {
      return false;
    }
    await _player.open(Media('asset:///${s.asset}'), play: false);
    try {
      await _player.stream.duration.firstWhere((d) => d > Duration.zero).timeout(const Duration(seconds: 3));
    } catch (_) {}
    _loadedAsset = s.asset;
    return true;
  }

  void _finished() {
    _player.pause();
    _clear();
  }

  void _stopLocal() {
    _gen++;
    _player.pause();
    _clear();
  }

  void _clear() {
    _endTimer?.cancel();
    playing = null;
    starting = null;
    _playingSeq = null;
    notifyListeners();
  }
}
