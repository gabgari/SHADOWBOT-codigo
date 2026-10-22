import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'vision_discovery/vision_discovery.dart';

/// Una detección de YOLO tal como la manda `/estado` (`caja` = x1, y1, x2,
/// y2 en píxeles del cuadro de 1280×720). [etiqueta] ya viene en español
/// ("Persona", "Oxido severo"…) y [categoria] es una de
/// [VisionCategory.all].
class VisionDetection {
  final String clase;
  final String etiqueta;
  final String categoria;
  final double confianza;
  final List<int> caja;
  const VisionDetection(this.clase, this.confianza, this.caja, {this.etiqueta = '', this.categoria = ''});

  /// El servidor viejo solo mandaba `clase: fire`.
  bool get isFire => categoria == VisionCategory.fuego || (categoria.isEmpty && clase == 'fire');

  static VisionDetection? fromJson(dynamic j) {
    if (j is! Map) return null;
    final caja = (j['caja'] as List?)?.map((e) => (e as num).round()).toList() ?? const [];
    return VisionDetection(
      '${j['clase'] ?? ''}',
      (j['confianza'] as num?)?.toDouble() ?? 0,
      caja,
      etiqueta: '${j['etiqueta'] ?? ''}',
      categoria: '${j['categoria'] ?? ''}',
    );
  }
}

/// Categorías de `/estado` (`conteo` y `detecciones[].categoria`), con su
/// ícono y nombre para el resumen.
class VisionCategory {
  static const fuego = 'fuego';
  static const persona = 'persona';
  static const vehiculo = 'vehiculo';
  static const animal = 'animal';
  static const objeto = 'objeto';
  static const fisura = 'fisura';
  static const oxido = 'oxido';
  static const all = [fuego, persona, vehiculo, animal, objeto, fisura, oxido];

  static String emoji(String c) => switch (c) {
        fuego => '🔥',
        persona => '👤',
        vehiculo => '🚗',
        animal => '🐕',
        objeto => '📦',
        fisura => '🧱',
        oxido => '🟤',
        _ => '•',
      };

  /// Nombre en el resumen (las personas, vehículos… van solo con su ícono).
  static String label(String c) => switch (c) {
        fuego => 'Fuego',
        fisura => 'Fisuras',
        oxido => 'Óxido',
        _ => '',
      };

  static String name(String c, int n) => switch (c) {
        persona => n == 1 ? 'Persona' : 'Personas',
        vehiculo => n == 1 ? 'Vehículo' : 'Vehículos',
        animal => n == 1 ? 'Animal' : 'Animales',
        objeto => n == 1 ? 'Objeto' : 'Objetos',
        fisura => n == 1 ? 'Fisura' : 'Fisuras',
        oxido => 'Óxido / corrosión',
        fuego => 'Fuego',
        _ => c,
      };
}

/// Modos de la PC de visión (`/modo`): qué detecta y qué tan rápido va.
class VisionMode {
  static const fuego = 'fuego';
  static const seguridad = 'seguridad';
  static const inspeccion = 'inspeccion';
  static const todo = 'todo';
  static const defaults = [fuego, seguridad, inspeccion, todo];

  static String emoji(String m) => switch (m) {
        fuego => '🔥',
        seguridad => '🛡',
        inspeccion => '🔧',
        todo => '✨',
        _ => '•',
      };

  static String label(String m) => switch (m) {
        fuego => 'Fuego',
        seguridad => 'Seguridad',
        inspeccion => 'Inspección',
        todo => 'Todo',
        _ => m.isEmpty ? '—' : m[0].toUpperCase() + m.substring(1),
      };

  /// Velocidad aproximada (fuego ~19 fps, seguridad ~11, inspección ~5, todo ~4).
  static String speed(String m) => switch (m) {
        fuego => 'rápido',
        seguridad => 'normal',
        _ => 'lento',
      };

  static String detail(String m) => switch (m) {
        fuego => 'Solo fuego',
        seguridad => 'Fuego + personas, animales, vehículos y objetos',
        inspeccion => 'Fuego + fisuras y óxido (revisar chasis)',
        todo => 'Todo junto',
        _ => '',
      };
}

/// Aviso para la UI: [alarm] = fuego (banner rojo + vibración); [soft] =
/// aviso discreto (persona en SEGURIDAD, fisura/óxido en INSPECCIÓN: solo un
/// SnackBar); si no, un mensaje normal (p. ej. "la PC de visión se
/// desconectó").
class VisionNotice {
  final String text;
  final bool alarm;
  final bool soft;
  const VisionNotice(this.text, {this.alarm = false, this.soft = false});
}

/// PC de VISIÓN IA: una PC en la misma red corre YOLO sobre la cámara Tapo
/// (CAM 2) y publica el video ya procesado (recuadros + "FUEGO DETECTADO")
/// por HTTP. No siempre está encendida, así que todo aquí es opcional: si
/// no responde, CAM 2 sigue por RTSP directo como siempre.
///
///   GET /salud     -> {"ok": true}
///   GET /video     -> MJPEG (multipart/x-mixed-replace; boundary=frame), ~15 fps 1280×720
///   GET /foto.jpg  -> último cuadro con recuadros
///   GET /estado    -> {"camara": bool, "fuego": bool, "fps": n, "detecciones": [...]}
///
/// Este servicio no dibuja nada: lleva la dirección (configurable, guardada
/// en el teléfono), si la PC está disponible (/salud cada 5 s, y `camara`
/// de /estado), qué fuente eligió el usuario para CAM 2 (RTSP o IA), el
/// stream MJPEG compartido (una sola conexión para el visor y la grabación,
/// abierta solo mientras alguien la use — ver [acquire]) y la alerta de
/// fuego (/estado cada 1 s en modo IA, con antirrebote de 10 s).
///
/// Dirección: la PC se anuncia sola por UDP (puerto 5001, ver
/// [VisionDiscovery]) y la app la toma sin que el usuario escriba nada. La
/// IP manual queda de respaldo: si el usuario escribió una y responde
/// /salud, se usa esa; si no, la descubierta.
class VisionService extends ChangeNotifier {
  static const defaultHost = '192.168.3.54:5000';
  static const _keyHost = 'vision_host'; // la que escribió el usuario
  static const _keyDiscovered = 'vision_discovered'; // la última anunciada por UDP
  static const _keySource = 'cam2_source'; // 'rtsp' | 'ia'

  static const _healthEvery = Duration(seconds: 5);
  static const _healthTimeout = Duration(seconds: 2);
  static const _estadoEvery = Duration(seconds: 1);
  static const _alertCooldown = Duration(seconds: 10);

  VisionService() {
    _discovery = VisionDiscovery(onFound: _onDiscovered);
    _load();
  }

  // ---------------- Dirección de la PC ----------------

  /// `IP:puerto` en uso ahora (sin http://): la manual si responde, si no la
  /// descubierta.
  String host = defaultHost;

  /// La que escribió el usuario en Ajustes ('' = ninguna).
  String manualHost = '';

  /// La última que anunció la PC por UDP ('' = nunca se ha visto).
  String discoveredHost = '';

  /// Cuándo llegó el último anuncio en esta sesión (null = aún buscando).
  DateTime? discoveredAt;

  late final VisionDiscovery _discovery;

  static String _normalize(String value) {
    var v = value.trim().replaceFirst(RegExp(r'^https?://'), '');
    while (v.endsWith('/')) {
      v = v.substring(0, v.length - 1);
    }
    return v;
  }

  /// Direcciones a probar, en orden de preferencia.
  List<String> get _candidates {
    final c = <String>[if (manualHost.isNotEmpty) manualHost, if (discoveredHost.isNotEmpty && discoveredHost != manualHost) discoveredHost];
    return c.isEmpty ? const [defaultHost] : c;
  }

  Uri _uri(String path) => Uri.parse('http://$host$path');
  Uri get videoUri => _uri('/video');
  Uri get fotoUri => _uri('/foto.jpg');

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      manualHost = prefs.getString(_keyHost) ?? '';
      discoveredHost = prefs.getString(_keyDiscovered) ?? '';
      useIa = prefs.getString(_keySource) == 'ia';
    } catch (_) {}
    host = _candidates.first;
    unawaited(_discovery.start());
    // El timer no encola revisiones: si la anterior sigue, se salta.
    _healthTimer = Timer.periodic(_healthEvery, (_) {
      if (_inflight == null) checkHealth();
    });
    await checkHealth();
  }

  /// IP manual (acepta "192.168.3.54:5000" o "http://…/"). Vacía = usar
  /// solo la que se descubre sola.
  Future<void> setHost(String value) async {
    manualHost = _normalize(value);
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      if (manualHost.isEmpty) {
        await prefs.remove(_keyHost);
      } else {
        await prefs.setString(_keyHost, manualHost);
      }
    } catch (_) {}
    await checkHealth();
  }

  /// Llegó un anuncio UDP de la PC (cada 2 s).
  void _onDiscovered(String url) {
    final v = _normalize(url);
    if (v.isEmpty) return;
    final first = discoveredAt == null;
    discoveredAt = DateTime.now();
    if (v == discoveredHost && !first) return;
    final changed = v != discoveredHost;
    discoveredHost = v;
    notifyListeners();
    if (changed) {
      // Otra red / otra IP: se guarda y reemplaza a la anterior.
      SharedPreferences.getInstance().then((p) => p.setString(_keyDiscovered, v)).catchError((Object _) => false);
    }
    // Si no estaba disponible (o estaba usando la vieja), validar ya.
    if (!available || host != manualHost) checkHealth();
  }

  void _useHost(String h) {
    if (h == host) return;
    host = h;
    _closeStream(); // el visor/grabación se reconectan solos a la nueva
    notifyListeners();
  }

  /// El último cuadro procesado (`/foto.jpg`), para fotos sin el visor abierto.
  Future<Uint8List?> fetchPhoto() async {
    try {
      final res = await http.get(fotoUri).timeout(const Duration(seconds: 4));
      return res.statusCode == 200 ? res.bodyBytes : null;
    } catch (_) {
      return null;
    }
  }

  // ---------------- Disponibilidad ----------------

  /// La PC responde a /salud y recibe video de la cámara.
  bool available = false;

  /// IP de la cámara Tapo que encontró la PC (`camara_ip` de /estado).
  String? cameraIp;

  void _readCameraIp(Map j) {
    final ip = j['camara_ip'];
    if (ip is String && ip.isNotEmpty && ip != cameraIp) {
      cameraIp = ip;
      notifyListeners();
    }
  }

  /// Ya se hizo al menos una consulta (para no mostrar "no disponible"
  /// durante el primer segundo de la app).
  bool checked = false;
  Timer? _healthTimer;
  Future<bool>? _inflight;

  /// Consulta /salud (timeout 2 s) y /estado (`camara`) en la IP manual y,
  /// si no responde, en la descubierta; se queda con la primera que sirva.
  /// Devuelve si quedó disponible. La llama un timer cada 5 s, la UI al
  /// abrir la pantalla y cada anuncio UDP nuevo.
  ///
  /// Si ya hay una revisión en curso, espera a que termine y hace otra
  /// (así, al guardar una IP nueva, el resultado es el de esa IP).
  Future<bool> checkHealth() async {
    while (_inflight != null) {
      await _inflight;
    }
    final f = _checkHealth();
    _inflight = f;
    try {
      return await f;
    } finally {
      _inflight = null;
    }
  }

  Future<bool> _checkHealth() async {
    var ok = false;
    try {
      final candidates = _candidates;
      for (final h in candidates) {
        if (await _probe(h)) {
          _useHost(h);
          ok = true;
          break;
        }
      }
      if (!ok) _useHost(candidates.first);
    } catch (_) {
      ok = false;
    }
    _setAvailable(ok);
    return ok;
  }

  Future<bool> _probe(String h) async {
    try {
      final res = await http.get(Uri.parse('http://$h/salud')).timeout(_healthTimeout);
      if (res.statusCode != 200) return false;
      final j = jsonDecode(res.body);
      if (j is! Map || j['ok'] != true) return false;
      // PC encendida pero sin video de la cámara = IA no disponible.
      final e = await _fetchEstado(h);
      if (e != null) _readCameraIp(e);
      return !(e != null && e['camara'] == false);
    } catch (_) {
      return false;
    }
  }

  void _setAvailable(bool ok) {
    final was = available;
    available = ok;
    checked = true;
    if (was && !ok && useIa) {
      // Estaba viendo la IA y la PC se cayó: vuelve solo a RTSP y avisa.
      useIa = false;
      _saveSource();
      _notice(const VisionNotice('PC de visión no disponible — CAM 2 volvió a la cámara directa (RTSP)'));
    }
    if (was != ok) {
      _syncStream();
      _syncEstado();
      notifyListeners();
    }
  }

  // ---------------- Fuente de CAM 2 ----------------

  /// El usuario eligió "Visión IA" para CAM 2 (se recuerda en el teléfono).
  bool useIa = false;

  /// CAM 2 se está mostrando con la IA (elegida Y disponible).
  bool get iaActive => useIa && available;

  /// Cambia la fuente. Con [force] = false no deja elegir IA si la PC no
  /// está disponible. Bloquear el cambio durante una grabación es cosa de
  /// quien llama (ver `AppState.setCam2Ia`).
  Future<void> setUseIa(bool v) async {
    if (v && !available) return;
    if (v == useIa) return;
    useIa = v;
    _fire = false;
    detections = const [];
    conteo = const {};
    _prevConteo = const {};
    _syncStream();
    _syncEstado();
    notifyListeners();
    await _saveSource();
  }

  Future<void> _saveSource() async {
    try {
      await (await SharedPreferences.getInstance()).setString(_keySource, useIa ? 'ia' : 'rtsp');
    } catch (_) {}
  }

  // ---------------- Avisos para la UI ----------------

  final _notices = StreamController<VisionNotice>.broadcast();

  /// Avisos (PC caída, fuego). `main.dart` los muestra como SnackBar.
  Stream<VisionNotice> get notices => _notices.stream;
  void _notice(VisionNotice n) {
    if (!_notices.isClosed) _notices.add(n);
  }

  // ---------------- Modo de la PC (/modo) ----------------

  /// Modo actual de la PC (`fuego`, `seguridad`, `inspeccion`, `todo`);
  /// null = aún no se sabe (o servidor viejo sin /modo).
  String? modo;
  List<String> modos = VisionMode.defaults;

  /// Hay un cambio de modo en camino (para la UI).
  String? modoPending;

  void _readModo(Map j) {
    final m = j['modo'];
    final list = j['modos'];
    if (list is List && list.isNotEmpty) modos = list.map((e) => '$e').toList();
    if (m is String && m.isNotEmpty) modo = m;
  }

  /// Lee el modo actual (`GET /modo`). `null` si no responde.
  Future<String?> getModo() async {
    try {
      final res = await http.get(_uri('/modo')).timeout(_healthTimeout);
      if (res.statusCode != 200) return null;
      final j = jsonDecode(res.body);
      if (j is! Map) return null;
      final before = modo;
      _readModo(j);
      if (modo != before) notifyListeners();
      return modo;
    } catch (_) {
      return null;
    }
  }

  /// Cambia el modo (`GET /modo?m=`). Devuelve `null` si quedó, o un texto
  /// de error para el usuario.
  Future<String?> setModo(String m) async {
    if (!available) return 'PC de visión no disponible';
    modoPending = m;
    notifyListeners();
    try {
      final res = await http.get(_uri('/modo').replace(queryParameters: {'m': m})).timeout(const Duration(seconds: 4));
      if (res.statusCode == 400) return 'La PC de visión no acepta el modo "$m"';
      if (res.statusCode != 200) return 'La PC de visión no cambió de modo (HTTP ${res.statusCode})';
      final j = jsonDecode(res.body);
      if (j is Map) _readModo(j);
      _prevConteo = const {}; // otro modo: las categorías "aparecen" de nuevo
      return null;
    } catch (_) {
      return 'La PC de visión no respondió al cambio de modo';
    } finally {
      modoPending = null;
      notifyListeners();
    }
  }

  // ---------------- /estado: fuego, conteo, detecciones ----------------

  bool _fire = false;

  /// La IA ve fuego ahora mismo (solo en modo IA).
  bool get fire => iaActive && _fire;
  List<VisionDetection> detections = const [];

  /// Cuántos hay de cada categoría ahora (`conteo` de /estado; solo > 0).
  Map<String, int> conteo = const {};
  Map<String, int> _prevConteo = const {};
  final Map<String, DateTime> _lastSoft = {};
  static const _softCooldown = Duration(seconds: 15);

  /// Confianza más alta de las detecciones de fuego (para el banner).
  double? get fireConfidence {
    final f = detections.where((d) => d.isFire);
    return f.isEmpty ? null : f.map((d) => d.confianza).reduce((a, b) => a > b ? a : b);
  }

  double? fps;
  Timer? _estadoTimer;
  bool _estadoBusy = false;
  DateTime _lastAlert = DateTime(0);

  Future<Map<String, dynamic>?> _fetchEstado([String? h]) async {
    try {
      final res = await http.get(h == null ? _uri('/estado') : Uri.parse('http://$h/estado')).timeout(_healthTimeout);
      if (res.statusCode != 200) return null;
      final j = jsonDecode(res.body);
      return j is Map<String, dynamic> ? j : null;
    } catch (_) {
      return null;
    }
  }

  void _syncEstado() {
    if (iaActive) {
      if (_estadoTimer == null) {
        _estadoTimer = Timer.periodic(_estadoEvery, (_) => _pollEstado());
        getModo(); // al entrar a VISIÓN IA se muestra el modo actual
      }
    } else {
      _estadoTimer?.cancel();
      _estadoTimer = null;
      conteo = const {};
      _prevConteo = const {};
      if (_fire) {
        _fire = false;
        notifyListeners();
      }
    }
  }

  Future<void> _pollEstado() async {
    if (_estadoBusy || !iaActive) return;
    _estadoBusy = true;
    try {
      final j = await _fetchEstado();
      if (j == null) return; // un /estado perdido no tumba nada; /salud decide
      if (j['camara'] == false) {
        _setAvailable(false);
        return;
      }
      _readCameraIp(j);
      final nowFire = j['fuego'] == true;
      final dets = (j['detecciones'] as List?)?.map(VisionDetection.fromJson).whereType<VisionDetection>().toList() ?? const <VisionDetection>[];
      fps = (j['fps'] as num?)?.toDouble();
      // El modo pudo cambiar desde Telegram o la propia PC.
      final prevModo = modo;
      if (j['modo'] is String && (j['modo'] as String).isNotEmpty) modo = j['modo'] as String;
      final nowConteo = <String, int>{};
      final rawConteo = j['conteo'];
      if (rawConteo is Map) {
        rawConteo.forEach((k, v) {
          final n = v is num ? v.round() : 0;
          if (n > 0) nowConteo['$k'] = n;
        });
      }
      final changed = nowFire != _fire || dets.length != detections.length || modo != prevModo || !mapEquals(nowConteo, conteo);
      _fire = nowFire;
      detections = dets;
      conteo = nowConteo;
      if (nowFire) {
        final now = DateTime.now();
        if (now.difference(_lastAlert) >= _alertCooldown) {
          _lastAlert = now;
          final conf = fireConfidence;
          _notice(VisionNotice(
            conf == null ? 'FUEGO DETECTADO por la IA' : 'FUEGO DETECTADO por la IA (${(conf * 100).round()} %)',
            alarm: true,
          ));
        }
      }
      _softAlerts(nowConteo);
      if (changed) notifyListeners();
    } finally {
      _estadoBusy = false;
    }
  }

  /// Avisos discretos: aparece una persona en SEGURIDAD, o una fisura / óxido
  /// en INSPECCIÓN (como máximo uno cada 15 s por categoría). Con el modo
  /// TODO no se avisa (sería ruido constante); el fuego va aparte.
  void _softAlerts(Map<String, int> now) {
    final watch = switch (modo) {
      VisionMode.seguridad => const [VisionCategory.persona],
      VisionMode.inspeccion => const [VisionCategory.fisura, VisionCategory.oxido],
      _ => const <String>[],
    };
    final t = DateTime.now();
    for (final c in watch) {
      final n = now[c] ?? 0;
      final appeared = n > 0 && (_prevConteo[c] ?? 0) == 0;
      if (!appeared) continue;
      final last = _lastSoft[c];
      if (last != null && t.difference(last) < _softCooldown) continue;
      _lastSoft[c] = t;
      final what = c == VisionCategory.persona ? (n == 1 ? 'Persona detectada' : '$n personas detectadas') : '${VisionCategory.name(c, n)} detectad${c == VisionCategory.fisura ? (n == 1 ? 'a' : 'as') : 'o'} ($n)';
      _notice(VisionNotice('${VisionCategory.emoji(c)} $what', soft: true));
    }
    _prevConteo = now;
  }

  // ---------------- Stream MJPEG compartido ----------------
  // Una sola conexión a /video para el visor y para la grabación. Se abre
  // mientras alguien la "tome" (acquire) y la IA esté activa, y se cierra al
  // soltarla, al volver a RTSP o si la PC se cae.

  int _users = 0;
  http.Client? _client;
  StreamSubscription<List<int>>? _sub;
  Timer? _retry;

  /// Último JPEG recibido (con los recuadros de la IA). El visor lo escucha
  /// directo para no repintar toda la app 15 veces por segundo.
  final frame = ValueNotifier<Uint8List?>(null);
  DateTime lastFrameAt = DateTime(0);

  final _frames = StreamController<Uint8List>.broadcast();

  /// Cada JPEG que llega (lo usa la grabación).
  Stream<Uint8List> get frames => _frames.stream;

  /// `true` si llegó un cuadro hace menos de [age].
  bool hasFreshFrame([Duration age = const Duration(seconds: 2)]) => frame.value != null && DateTime.now().difference(lastFrameAt) < age;

  void acquire() {
    _users++;
    _syncStream();
  }

  void release() {
    if (_users > 0) _users--;
    _syncStream();
  }

  void _syncStream() {
    final want = _users > 0 && iaActive;
    if (want && _client == null) {
      _openStream();
    } else if (!want && _client != null) {
      _closeStream();
    }
  }

  void _openStream() {
    _retry?.cancel();
    final client = http.Client();
    _client = client;
    final parser = MjpegPartParser((jpeg) {
      frame.value = jpeg;
      lastFrameAt = DateTime.now();
      if (_frames.hasListener) _frames.add(jpeg);
    });
    client.send(http.Request('GET', videoUri)).then((res) {
      if (_client != client) return;
      if (res.statusCode != 200) {
        _onStreamError(client);
        return;
      }
      _sub = res.stream.listen(parser.add, onError: (_) => _onStreamError(client), onDone: () => _onStreamError(client), cancelOnError: true);
    }).catchError((Object _) {
      _onStreamError(client);
    });
  }

  /// Se cortó el stream: reintenta en 1 s si todavía se necesita.
  void _onStreamError(http.Client client) {
    if (_client != client) return;
    _closeStream();
    _retry = Timer(const Duration(seconds: 1), _syncStream);
  }

  void _closeStream() {
    _retry?.cancel();
    _retry = null;
    _sub?.cancel();
    _sub = null;
    _client?.close();
    _client = null;
  }

  @override
  void dispose() {
    _discovery.stop(); // cierra el socket UDP y suelta el MulticastLock
    _healthTimer?.cancel();
    _estadoTimer?.cancel();
    _closeStream();
    _notices.close();
    _frames.close();
    frame.dispose();
    super.dispose();
  }
}

/// Separa un stream `multipart/x-mixed-replace` en JPEGs. Usa el
/// `Content-Length` de cada parte cuando viene (lo normal en la PC de
/// visión) y, si no, busca las marcas JPEG SOI (FFD8) / EOI (FFD9).
@visibleForTesting
class MjpegPartParser {
  final void Function(Uint8List jpeg) onFrame;
  MjpegPartParser(this.onFrame);

  Uint8List _buf = Uint8List(256 * 1024);
  int _len = 0;
  int? _need; // bytes del JPEG actual según Content-Length
  int _scan = 0; // dónde seguir buscando (evita re-escanear)
  bool _noLength = false; // el servidor no manda Content-Length: solo marcas JPEG

  static const _maxBuffer = 8 * 1024 * 1024;

  void add(List<int> chunk) {
    if (_len + chunk.length > _buf.length) {
      var size = _buf.length * 2;
      while (size < _len + chunk.length) {
        size *= 2;
      }
      final nb = Uint8List(size)..setRange(0, _len, _buf);
      _buf = nb;
    }
    _buf.setRange(_len, _len + chunk.length, chunk);
    _len += chunk.length;
    _drain();
    if (_len > _maxBuffer) _reset(); // basura sin fin: empezar de cero
  }

  void _drain() {
    if (_noLength) {
      while (_bySoiEoi()) {}
      return;
    }
    while (true) {
      if (_need != null) {
        if (_len < _need!) return;
        _emit(0, _need!);
        _consume(_need!);
        _need = null;
        continue;
      }
      // Encabezados de la parte: hasta "\r\n\r\n".
      final hdrEnd = _find(const [13, 10, 13, 10], _scan);
      if (hdrEnd == -1) {
        _scan = _len > 3 ? _len - 3 : 0;
        return;
      }
      final headers = latin1.decode(_buf.sublist(0, hdrEnd), allowInvalid: true).toLowerCase();
      final m = RegExp(r'content-length:\s*(\d+)').firstMatch(headers);
      _consume(hdrEnd + 4);
      _scan = 0;
      if (m != null) {
        _need = int.parse(m.group(1)!);
      } else {
        _noLength = true;
        while (_bySoiEoi()) {}
        return;
      }
    }
  }

  /// Plan B sin Content-Length: el JPEG va de FFD8 a FFD9.
  bool _bySoiEoi() {
    final start = _find(const [0xFF, 0xD8], 0);
    if (start == -1) return false;
    final end = _find(const [0xFF, 0xD9], start + 2);
    if (end == -1) return false;
    _emit(start, end + 2 - start);
    _consume(end + 2);
    _scan = 0;
    return true;
  }

  void _emit(int from, int length) {
    // Solo si de verdad es un JPEG (empieza con FFD8).
    if (length > 2 && _buf[from] == 0xFF && _buf[from + 1] == 0xD8) {
      onFrame(Uint8List.fromList(Uint8List.sublistView(_buf, from, from + length)));
    }
  }

  void _consume(int n) {
    _buf.setRange(0, _len - n, _buf, n);
    _len -= n;
  }

  int _find(List<int> pat, int from) {
    final last = _len - pat.length;
    outer:
    for (var i = from < 0 ? 0 : from; i <= last; i++) {
      for (var k = 0; k < pat.length; k++) {
        if (_buf[i + k] != pat[k]) continue outer;
      }
      return i;
    }
    return -1;
  }

  void _reset() {
    _len = 0;
    _need = null;
    _scan = 0;
    _noLength = false;
  }
}
