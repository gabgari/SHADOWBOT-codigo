import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/node_link.dart';
import 'device_config.dart';
import 'lan_scan/lan_scan.dart';

/// Cliente de video para la cámara IP TP-Link Tapo C110, por RTSP.
///
/// A diferencia del ESP32-CAM (MJPEG por HTTP, ver `Esp32CamService`), la
/// Tapo habla RTSP con audio embebido (su micrófono). No hay firmware
/// propio que tocar: solo hace falta la URL RTSP completa que se configura
/// en la propia cámara (usuario/clave de "Cuenta de cámara" en la app Tapo,
/// puerto 554), algo como:
///   rtsp://usuario:clave@192.168.x.x:554/stream1   (HD)
///   rtsp://usuario:clave@192.168.x.x:554/stream2   (SD, menos ancho de banda)
///
/// Esa URL completa se guarda en `DeviceConfig` como si fuera el "host" de
/// este nodo (`HardwareNode.tapoCam`) — así se reutiliza el mismo
/// mecanismo de persistencia/edición que ya tienen los otros nodos, sin
/// inventar un campo nuevo.
///
/// *** Sobre el bocina/altavoz de la cámara (audio de ida, no solo vuelta) ***
/// El Tapo C110 SÍ tiene altavoz y soporta audio bidireccional, pero solo a
/// través del protocolo propietario cifrado de TP-Link (el que usa la app
/// Tapo) — no es parte del RTSP estándar ni de ONVIF en este modelo. No hay
/// forma soportada de "hablar por la cámara" desde una app propia sin ese
/// SDK privado, así que esa mitad queda descartada a propósito: lo que sí
/// se ofrece aquí es escuchar su micrófono (audio embebido en el RTSP) y
/// silenciarlo/activarlo desde la app — eso es 100% RTSP estándar.
class TapoCamService extends ChangeNotifier {
  final DeviceConfig config;

  TapoCamService(this.config);

  // El Player nativo (libmpv) se crea recién al primer uso real, no en el
  // constructor: `AppState` crea este servicio para TODOS los usuarios de
  // la app, hayan vinculado una Tapo o no. Crear el Player de una exige
  // tener `MediaKit.ensureInitialized()` corrido y la librería nativa
  // disponible (falla en `flutter test`, donde no hay libmpv en el PATH) —
  // con esto, quien nunca configura la Tapo nunca paga ese costo ni ese
  // riesgo.
  Player? _playerInstance;
  VideoController? _controllerInstance;
  Player get _player => _playerInstance ??= Player();
  VideoController get controller => _controllerInstance ??= VideoController(_player);

  // URL a la que se abrió (o se está intentando abrir) el stream. A
  // diferencia de una versión anterior de este servicio, NO se marca como
  // "conectada" hasta que de verdad hay un intento en curso sin error — si
  // `open()` falla (URL mala, cámara apagada, etc.) hay que poder
  // reintentar contra la MISMA url la próxima vez que se llame
  // `ensureConnected()`, no quedarse pegado para siempre.
  String? _attemptedUrl;
  DateTime? _lastAttempt;
  static const _retryCooldown = Duration(seconds: 4);

  /// Si tras abrir pasan esto sin video (o el video se cortó sin marcar
  /// error), se vuelve a abrir solo: antes se quedaba esperando para
  /// siempre (p. ej. la app abrió antes de que la Tapo terminara de
  /// arrancar, o un corte del Wi-Fi/hotspot).
  static const _stallTimeout = Duration(seconds: 12);
  bool _tuned = false;
  StreamSubscription<bool>? _completedSub;

  /// RTSP por TCP (como VLC/FFmpeg en el detector): por UDP, en Wi-Fi o en
  /// el hotspot del celular, los paquetes de video se pierden y a veces no
  /// llega imagen. Más un timeout de red para que un corte se detecte.
  Future<void> _tunePlayer() async {
    if (_tuned) return;
    _tuned = true;
    try {
      final dynamic native = _player.platform; // NativePlayer (no existe en Web)
      await native.setProperty('rtsp-transport', 'tcp');
      await native.setProperty('network-timeout', '10');
    } catch (_) {}
  }

  /// Sonido (micrófono) de la cámara silenciado. Se guarda en el teléfono;
  /// se cambia en Cámaras, en el visor de la consola y en pantalla completa.
  static const _keyMuted = 'tapo_muted';
  bool _muted = false;
  bool get muted => _muted;
  bool _mutedLoaded = false;

  Future<void> _loadMuted() async {
    if (_mutedLoaded) return;
    _mutedLoaded = true;
    try {
      _muted = (await SharedPreferences.getInstance()).getBool(_keyMuted) ?? _muted;
    } catch (_) {}
  }

  StreamSubscription<String>? _errorSub;
  StreamSubscription<bool>? _playingSub;
  String? lastError;

  String get _rtspUrl => config.of(HardwareNode.tapoCam).host;
  bool get isConfigured => _rtspUrl.isNotEmpty;

  // Ojo con estos dos: deben poder consultarse SIEMPRE (p.ej. el punto de
  // estado en `camara_screen.dart` se pinta exista o no una URL guardada)
  // sin disparar la creación perezosa del Player — por eso miran
  // `_playerInstance` directo en vez de pasar por el getter `_player`.
  Stream<bool>? get playingStream => _playerInstance?.stream.playing;
  bool get isPlaying => _playerInstance?.state.playing ?? false;

  /// Abre (o reabre, si cambió la URL o el intento anterior falló) el
  /// stream RTSP. Se puede llamar tantas veces como se quiera — p.ej. desde
  /// `build()` de la pantalla Cámara en cada rebuild — sin miedo a
  /// martillar la cámara: si ya está conectada a la misma URL y sin error
  /// no hace nada, y si hubo un error, reintenta como mucho cada
  /// [_retryCooldown].
  Future<void> ensureConnected() async {
    if (!isConfigured) return;
    final url = _rtspUrl;
    final sameUrl = _attemptedUrl == url;
    final now = DateTime.now();
    if (sameUrl && lastError == null) {
      // Ya conectada / conectando bien… salvo que lleve rato sin video.
      final stalled = !isPlaying && _lastAttempt != null && now.difference(_lastAttempt!) > _stallTimeout;
      if (!stalled) return;
    }
    if (sameUrl && _lastAttempt != null && now.difference(_lastAttempt!) < _retryCooldown) {
      return; // hubo error hace poco, todavía no toca reintentar
    }

    _attemptedUrl = url;
    _lastAttempt = now;
    lastError = null;
    _errorSub ??= _player.stream.error.listen((e) {
      lastError = e;
      notifyListeners();
    });
    // Sin esto, `isPlaying` cambia por dentro (el widget `Video` sí lo ve,
    // porque escucha al Player directo) pero nada le avisa a Provider que
    // hay que repintar cosas como el punto de estado — se quedaría
    // mostrando "desconectado" un rato después de que el stream ya esté
    // corriendo.
    _playingSub ??= _player.stream.playing.listen((playing) {
      if (playing) lastError = null; // se recuperó solo (blip de red, etc.)
      notifyListeners();
    });
    // Un RTSP en vivo no "termina": si mpv dice que acabó, se cortó.
    _completedSub ??= _player.stream.completed.listen((done) {
      if (!done) return;
      lastError = 'El video de la cámara se cortó';
      notifyListeners();
    });
    try {
      await _tunePlayer();
      await _loadMuted();
      await _player.open(Media(url));
      await _player.setVolume(_muted ? 0 : 100);
    } catch (e) {
      lastError = e.toString();
      notifyListeners();
    }
  }

  /// Cuándo se abrió (o reabrió) el stream por última vez; null = nunca.
  DateTime? get lastAttempt => _lastAttempt;

  // ---------------- Buscar la Tapo en la red ----------------
  // En otra red (hotspot del celular con el mismo nombre y contraseña) la
  // Tapo recibe otra IP y la URL guardada deja de servir. Sin depender de
  // la PC de visión: se buscan en la red del teléfono los equipos con el
  // puerto RTSP (554) abierto y se prueba la URL guardada con esa IP
  // (mismo usuario, clave y stream).

  bool searching = false;
  DateTime lastSearch = DateTime(0);

  /// Busca la Tapo en la red. Devuelve la URL con la IP nueva (`url`,
  /// null si no halló otra) y un texto para el usuario. Solo acepta una
  /// cámara que reciba el usuario y la clave de la URL guardada (así no se
  /// confunde con otra cámara de la casa). [exclude] = IPs que ya fallaron.
  Future<({String? url, String message})> findOnLan({Set<String> exclude = const {}}) async {
    final uri = Uri.tryParse(_rtspUrl);
    if (uri == null || uri.scheme != 'rtsp' || uri.host.isEmpty) {
      return (url: null, message: 'Primero guarda la URL RTSP de la Tapo (rtsp://usuario:clave@IP:554/stream2)');
    }
    if (searching) return (url: null, message: 'Ya se está buscando…');
    searching = true;
    lastSearch = DateTime.now();
    notifyListeners();
    try {
      final found = await scanLanForPort(uri.hasPort ? uri.port : 554);
      final rejected = <String>[];
      for (final ip in found) {
        if (exclude.contains(ip)) continue;
        final candidate = uri.replace(host: ip);
        final ok = await rtspCredentialsOk(candidate);
        if (ok == true) {
          if (ip == uri.host) return (url: null, message: 'La Tapo está en $ip (la IP guardada) y acepta la clave; el video debería arrancar');
          return (url: candidate.toString(), message: 'CAM 2 encontrada en $ip');
        }
        if (ok == false) rejected.add(ip);
      }
      if (found.isEmpty) return (url: null, message: 'No hay ninguna cámara RTSP en esta red (¿la Tapo está encendida y en el mismo Wi-Fi?)');
      if (rejected.isNotEmpty) {
        return (
          url: null,
          message: 'Hay cámara(s) RTSP en ${rejected.join(', ')} pero ninguna acepta el usuario/clave de la URL. Revisa la "Cuenta de cámara" en la app Tapo.'
        );
      }
      return (url: null, message: 'Las cámaras RTSP de esta red no respondieron');
    } finally {
      searching = false;
      notifyListeners();
    }
  }

  Future<void> toggleMute() async {
    _muted = !_muted;
    notifyListeners();
    await _player.setVolume(_muted ? 0 : 100);
    try {
      await (await SharedPreferences.getInstance()).setBool(_keyMuted, _muted);
    } catch (_) {}
  }

  /// Prueba de conexión real para Sistema > Conexiones: abre el stream (o
  /// reusa el ya abierto) y espera a que llegue el primer frame (evento
  /// `playing`) o un error, lo que ocurra primero.
  Future<bool> checkReachable() async {
    if (!isConfigured) return false;
    await ensureConnected();
    if (_player.state.playing) return true;
    try {
      final playing = _player.stream.playing.firstWhere((p) => p);
      final error = _player.stream.error.first;
      final result = await Future.any<Object>([playing, error]).timeout(const Duration(seconds: 8));
      return result is bool && result;
    } catch (_) {
      return false;
    }
  }

  /// Captura el frame actual del stream como JPEG — mismo rol que
  /// `Esp32CamService.capture()`, para que `AssistantState` le pueda pasar
  /// una imagen a Gemini sin importar de qué cámara viene. A propósito NO
  /// depende de que la pantalla Cámara esté abierta: si piden "Analizar"
  /// con la Tapo como fuente (p.ej. desde Control, por voz) y el stream
  /// todavía no se había conectado, lo conecta aquí mismo y espera un poco
  /// al primer frame antes de rendirse.
  Future<Uint8List?> captureFrame() async {
    if (!isConfigured) return null;
    await ensureConnected();
    if (!isPlaying) {
      try {
        await _player.stream.playing.firstWhere((p) => p).timeout(const Duration(seconds: 6));
      } catch (_) {
        return null;
      }
    }
    try {
      return await _player.screenshot(format: 'image/jpeg');
    } catch (_) {
      return null;
    }
  }

  /// Frame actual sin codificar (píxeles BGR0 de mpv `screenshot-raw`),
  /// para grabar video y para fotos con filtro: `frame_filter.dart` les
  /// aplica el filtro y los codifica él mismo, sin pasar por el JPEG
  /// intermedio que arma `captureFrame()`. `null` si no hay video.
  ///
  /// Grabar el RTSP tal cual (propiedad `stream-record` de mpv) no sirve
  /// en Android: el libmpv de `media_kit_libs_android_video` viene
  /// compilado con `--disable-muxers`, así que no puede escribir ningún
  /// contenedor de video — por eso el video se arma frame a frame (ver
  /// `MediaLibrary`).
  Future<RawVideoFrame?> captureRaw({bool waitForVideo = false}) async {
    if (!isConfigured) return null;
    if (waitForVideo) {
      await ensureConnected();
      if (!isPlaying) {
        try {
          await _player.stream.playing.firstWhere((p) => p).timeout(const Duration(seconds: 6));
        } catch (_) {
          return null;
        }
      }
    }
    if (!isPlaying) return null;
    try {
      final bytes = await _player.screenshot(format: null);
      final w = _player.state.width;
      final h = _player.state.height;
      if (bytes == null || w == null || h == null || w <= 0 || h <= 0) return null;
      if (bytes.length % h != 0) return null;
      final stride = bytes.length ~/ h;
      if (stride < w * 4) return null;
      return RawVideoFrame(bytes, w, h, stride);
    } catch (_) {
      return null;
    }
  }

  @override
  void dispose() {
    _errorSub?.cancel();
    _playingSub?.cancel();
    _completedSub?.cancel();
    _playerInstance?.dispose(); // no usar el getter: no crear un Player solo para tirarlo
    super.dispose();
  }
}

/// Píxeles crudos BGR0 (4 bytes por píxel, [stride] bytes por fila).
class RawVideoFrame {
  final Uint8List bytes;
  final int width;
  final int height;
  final int stride;
  const RawVideoFrame(this.bytes, this.width, this.height, this.stride);
}
