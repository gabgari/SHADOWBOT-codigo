import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../services/esp32_cam_service.dart';
import '../services/frame_filter.dart';
import '../services/media_files/media_files.dart';
import '../services/tapo_cam_service.dart';
import '../services/vision_service.dart';
import '../widgets/camera_filters.dart';
import '../widgets/mjpeg_view.dart';
import 'app_state.dart' show AiCameraSource;

enum MediaKind { photo, video }

/// Una foto o video de la sección Multimedia.
class MediaItem {
  final String id;
  final MediaKind kind;
  final AiCameraSource source;

  /// Filtro con el que se capturó. Ya va "quemado" en los píxeles del
  /// archivo (ver `frame_filter.dart`) — se guarda solo para mostrarlo.
  final CameraFilterMode filter;
  final DateTime time;

  /// Ruta del archivo (o "Descargas del navegador" en Web).
  final String? path;

  /// Miniatura del video (su primer frame).
  final String? thumbPath;

  /// Bytes en memoria para mostrarla sin leer el archivo (Web, o recién
  /// tomada).
  final Uint8List? bytes;
  final int width;
  final int height;
  final int durationMs;
  final int frames;
  final int sizeBytes;

  /// Video de las 2 cámaras juntas (CAM 1 | CAM 2) en un solo archivo.
  final bool dual;

  /// CAM 2 grabada desde la PC de VISIÓN IA (con los recuadros de YOLO).
  final bool ia;

  const MediaItem({
    required this.id,
    required this.kind,
    required this.source,
    required this.filter,
    required this.time,
    this.path,
    this.thumbPath,
    this.bytes,
    this.width = 0,
    this.height = 0,
    this.durationMs = 0,
    this.frames = 0,
    this.sizeBytes = 0,
    this.dual = false,
    this.ia = false,
  });

  bool get isVideo => kind == MediaKind.video;
  String get camLabel => (dual ? 'CAM 1+2' : (source == AiCameraSource.tapoCam ? 'CAM 2' : 'CAM 1')) + (ia ? ' IA' : '');

  String get timeLabel => '${_two(time.hour)}:${_two(time.minute)}';
  String get dateLabel => '${_two(time.day)}/${_two(time.month)}/${time.year} ${_two(time.hour)}:${_two(time.minute)}:${_two(time.second)}';
  String get durationLabel => formatDuration(Duration(milliseconds: durationMs));

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind.name,
        'source': source.name,
        'filter': filter.name,
        'time': time.millisecondsSinceEpoch,
        'path': path,
        'thumb': thumbPath,
        'w': width,
        'h': height,
        'ms': durationMs,
        'frames': frames,
        'size': sizeBytes,
        if (dual) 'dual': true,
        if (ia) 'ia': true,
      };

  static MediaItem? fromJson(Map<String, dynamic> j) {
    try {
      return MediaItem(
        id: j['id'] as String,
        kind: MediaKind.values.byName(j['kind'] as String),
        source: AiCameraSource.values.byName(j['source'] as String),
        filter: CameraFilterMode.values.byName(j['filter'] as String),
        time: DateTime.fromMillisecondsSinceEpoch(j['time'] as int),
        path: j['path'] as String?,
        thumbPath: j['thumb'] as String?,
        width: j['w'] as int? ?? 0,
        height: j['h'] as int? ?? 0,
        durationMs: j['ms'] as int? ?? 0,
        frames: j['frames'] as int? ?? 0,
        sizeBytes: j['size'] as int? ?? 0,
        dual: j['dual'] == true,
        ia: j['ia'] == true,
      );
    } catch (_) {
      return null;
    }
  }
}

String _two(int n) => n.toString().padLeft(2, '0');

String formatDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  final s = d.inSeconds.remainder(60);
  return h > 0 ? '$h:${_two(m)}:${_two(s)}' : '${_two(m)}:${_two(s)}';
}

String formatBytes(int b) {
  if (b >= 1024 * 1024) return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
  if (b >= 1024) return '${(b / 1024).round()} KB';
  return '$b B';
}

/// Grabación en curso de una cámara.
class _Recording {
  final AiCameraSource source;
  final AviWriter writer;
  final String id;
  final DateTime started = DateTime.now();
  final CameraFilterMode filter;
  bool stopping = false;
  bool busy = false;
  StreamSubscription<Uint8List>? sub;
  Future<void>? loop;
  Future<void>? pending;
  String? thumbPath;
  DateTime lastFrame = DateTime.now();
  final bool dual;
  final bool ia; // CAM 2 viene de la PC de visión (tiene un acquire() pendiente)

  _Recording(this.source, this.writer, this.id, this.filter, {this.dual = false, this.ia = false});

  String get label => (dual ? 'CAM 1+2' : (source == AiCameraSource.tapoCam ? 'CAM 2' : 'CAM 1')) + (ia ? ' IA' : '');
}

/// Sección Multimedia: fotos y videos de las 2 cámaras, con el filtro que
/// tenía cada una al capturar, guardados en la carpeta `ShadowBot/` e
/// indexados en `multimedia.json` (ver `media_files_io.dart`).
///
/// Videos: el libmpv del APK no trae muxers ni encoders de video (ver
/// `TapoCamService.captureRaw`), así que se graban como Motion-JPEG en AVI
/// armado por la propia app: cada frame pasa por `frame_filter.dart`
/// (filtro + rotación), se codifica a JPEG y se agrega al archivo. Por eso
/// el video queda con el filtro de verdad, aunque se abra fuera de la app.
///   - CAM 2 (Tapo): toma frames del reproductor RTSP lo más rápido que da
///     el teléfono (~4-10 fps según el modelo), reducidos a 960 px. Sin
///     audio: el audio también necesitaría un muxer/encoder.
///   - CAM 1 (ESP32-CAM): usa los mismos JPEG del /stream que se ven en
///     pantalla (el ESP32 solo atiende un stream), así que graba mientras
///     su video esté visible en la app.
///   - CAM 2 en VISIÓN IA: los JPEG del MJPEG de la PC de visión (ya traen
///     los recuadros de YOLO), por la misma conexión que el visor
///     (`VisionService.acquire`). El archivo lleva el sufijo `_IA`. Si la PC
///     se cae a media grabación, se corta y se guarda lo grabado.
class MediaLibrary extends ChangeNotifier {
  final Esp32CamService camService;
  final TapoCamService tapoCam;
  final VisionService vision;
  final CameraFilterMode Function(AiCameraSource) filterOf;
  final void Function(bool ok, String text) onEvent;

  MediaLibrary({required this.camService, required this.tapoCam, required this.vision, required this.filterOf, required this.onEvent}) {
    _load();
    vision.addListener(_onVisionChanged);
  }

  /// La PC de visión se cayó (o el usuario volvió a RTSP): toda grabación
  /// que venía de la IA se corta guardando lo que ya tenía.
  void _onVisionChanged() {
    if (vision.iaActive) return;
    final tapo = _recordings[AiCameraSource.tapoCam];
    if (tapo != null && tapo.ia && !tapo.stopping) {
      unawaited(stopRecording(AiCameraSource.tapoCam).then((item) => onEvent(false,
          item == null ? 'PC de visión desconectada: la grabación IA no alcanzó a guardar nada' : 'PC de visión desconectada: video IA detenido y guardado (${item.durationLabel})')));
    }
    final dual = _dual;
    if (dual != null && dual.ia && !dual.stopping) {
      unawaited(stopDualRecording().then((item) => onEvent(false,
          item == null ? 'PC de visión desconectada: la grabación no alcanzó a guardar nada' : 'PC de visión desconectada: video CAM 1+2 IA detenido y guardado (${item.durationLabel})')));
    }
  }

  static const _tapoMaxSide = 960;
  static const _maxVideoBytes = 900 * 1024 * 1024; // AVI 1.0: lejos del límite de 1 GB

  final List<MediaItem> items = [];
  List<MediaItem> get photos => items.where((e) => !e.isVideo).toList();
  List<MediaItem> get videos => items.where((e) => e.isVideo).toList();

  bool get canRecordVideo => mediaFilesPersistent;

  Future<void> _load() async {
    try {
      final raw = await readMediaIndex();
      if (raw == null) return;
      final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      for (final j in list) {
        final item = MediaItem.fromJson(j);
        if (item == null || item.path == null) continue;
        if (!await mediaFileExists(item.path!)) continue; // lo borraron a mano
        items.add(item);
      }
      items.sort((a, b) => b.time.compareTo(a.time));
      notifyListeners();
    } catch (_) {}
  }

  Future<void> _saveIndex() async {
    if (!mediaFilesPersistent) return;
    try {
      await writeMediaIndex(jsonEncode(items.map((e) => e.toJson()).toList()));
    } catch (_) {}
  }

  // ---------------- Fotos ----------------

  /// Guarda una foto ya capturada aplicándole [filter] (y la rotación del
  /// montaje de la cámara). Devuelve el ítem guardado, o `null` si falló.
  Future<MediaItem?> savePhoto({required AiCameraSource source, required CameraFilterMode filter, Uint8List? jpeg, RawVideoFrame? raw}) async {
    final job = raw != null
        ? FrameJob.raw(raw.bytes, width: raw.width, height: raw.height, stride: raw.stride, filter: filter, quality: 90)
        : FrameJob.jpeg(jpeg!, filter: filter, quarterTurns: source == AiCameraSource.esp32cam ? kCamRotationQuarterTurns : 0, quality: 90);
    final result = await processFrameAsync(job);
    if (result == null) return null;
    final now = DateTime.now();
    final id = 'shadowbot_${source == AiCameraSource.tapoCam ? 'cam2' : 'cam1'}_${now.millisecondsSinceEpoch}';
    final path = await writeMediaBytes('$id.jpg', result.jpeg);
    final item = MediaItem(
      id: id,
      kind: MediaKind.photo,
      source: source,
      filter: filter,
      time: now,
      path: path,
      bytes: result.jpeg,
      width: result.width,
      height: result.height,
      sizeBytes: result.jpeg.length,
    );
    items.insert(0, item);
    notifyListeners();
    await _saveIndex();
    return item;
  }

  // ---------------- Videos ----------------

  final Map<AiCameraSource, _Recording> _recordings = {};
  Timer? _ticker;

  bool isRecording(AiCameraSource src) => _recordings.containsKey(src);
  bool get anyRecording => _recordings.isNotEmpty || _dual != null;
  Duration recordingElapsed(AiCameraSource src) {
    final r = _recordings[src];
    return r == null ? Duration.zero : DateTime.now().difference(r.started);
  }

  /// `true` si la grabación de [src] lleva >3 s sin recibir frames (p.ej.
  /// el video de CAM 1 no está en pantalla, o la Tapo se cortó).
  bool recordingStalled(AiCameraSource src) {
    final r = _recordings[src];
    return r != null && DateTime.now().difference(r.lastFrame) > const Duration(seconds: 3);
  }

  final Set<AiCameraSource> _toggling = {};
  bool isToggling(AiCameraSource src) => _toggling.contains(src);

  /// Empieza o detiene la grabación de [src]. Devuelve un texto para
  /// mostrar al usuario.
  Future<String> toggleRecording(AiCameraSource src) async {
    if (_toggling.contains(src)) return 'Espera…';
    _toggling.add(src);
    notifyListeners();
    try {
      if (isRecording(src)) {
        final item = await stopRecording(src);
        return item != null ? 'Video guardado en Multimedia (${item.durationLabel})' : 'La grabación no alcanzó a guardar ningún frame';
      }
      return await startRecording(src);
    } finally {
      _toggling.remove(src);
      notifyListeners();
    }
  }

  Future<String> startRecording(AiCameraSource src) async {
    final cam = src == AiCameraSource.tapoCam ? 'CAM 2' : 'CAM 1';
    if (isRecording(src)) return '$cam ya está grabando';
    if (!canRecordVideo) return 'Grabar video no está disponible en esta plataforma';

    final ia = src == AiCameraSource.tapoCam && vision.iaActive;
    if (ia) {
      // La fuente es la PC de visión: no hace falta la Tapo directa.
    } else if (src == AiCameraSource.tapoCam) {
      if (!tapoCam.isConfigured) return 'CAM 2 no vinculada — agrega la URL RTSP en Sistema › Conexiones';
      // Asegura que haya video antes de crear el archivo.
      final probe = await tapoCam.captureRaw(waitForVideo: true);
      if (probe == null) return 'No se pudo empezar a grabar: CAM 2 sin video';
    } else {
      if (!camService.isConfigured) return 'CAM 1 no vinculada — agrega la IP en Sistema › Conexiones';
    }

    final now = DateTime.now();
    final id = 'shadowbot_${src == AiCameraSource.tapoCam ? 'cam2' : 'cam1'}_${now.millisecondsSinceEpoch}${ia ? '_IA' : ''}';
    final writer = await openAviWriter('$id.avi');
    if (writer == null) return 'No se pudo crear el archivo de video';
    final rec = _Recording(src, writer, id, filterOf(src), ia: ia);
    _recordings[src] = rec;

    if (ia) {
      // Mantiene abierto el MJPEG de la PC aunque el visor no esté en pantalla.
      vision.acquire();
      rec.sub = vision.frames.listen((jpeg) {
        if (rec.busy || rec.stopping) return; // el teléfono va atrasado: se salta este frame
        rec.busy = true;
        rec.pending = _addFrame(rec, FrameJob.jpeg(jpeg, filter: filterOf(src), quality: 80)).whenComplete(() => rec.busy = false);
      });
    } else if (src == AiCameraSource.tapoCam) {
      rec.loop = _tapoLoop(rec);
    } else {
      rec.sub = camService.frames.listen((jpeg) {
        if (rec.busy || rec.stopping) return; // el teléfono va atrasado: se salta este frame
        rec.busy = true;
        rec.pending = _addFrame(rec, FrameJob.jpeg(jpeg, filter: filterOf(src), quarterTurns: kCamRotationQuarterTurns, quality: 80))
            .whenComplete(() => rec.busy = false);
      });
    }
    _ticker ??= Timer.periodic(const Duration(seconds: 1), (_) => notifyListeners());
    notifyListeners();
    if (ia) return 'Grabando $cam con VISIÓN IA';
    return src == AiCameraSource.esp32cam ? 'Grabando $cam — se graba mientras su video esté en pantalla' : 'Grabando $cam';
  }

  Future<void> _tapoLoop(_Recording rec) async {
    while (!rec.stopping) {
      final raw = await tapoCam.captureRaw();
      if (rec.stopping) break;
      if (raw == null) {
        await Future.delayed(const Duration(milliseconds: 250));
        continue;
      }
      // El filtro se lee en cada frame: si lo cambian a media grabación, el
      // video cambia igual que la vista en vivo.
      await _addFrame(
        rec,
        FrameJob.raw(raw.bytes, width: raw.width, height: raw.height, stride: raw.stride, filter: filterOf(rec.source), maxSide: _tapoMaxSide, quality: 75),
      );
    }
  }

  Future<void> _addFrame(_Recording rec, FrameJob job) => _addResult(rec, processFrameAsync(job));

  Future<void> _addResult(_Recording rec, Future<FrameResult?> frame) async {
    try {
      final result = await frame;
      if (result == null || rec.stopping) return;
      await rec.writer.addFrame(result.jpeg, result.width, result.height);
      rec.lastFrame = DateTime.now();
      if (rec.thumbPath == null) {
        rec.thumbPath = await writeMediaBytes('${rec.id}_thumb.jpg', result.jpeg);
        notifyListeners();
      }
      if (rec.writer.bytesWritten > _maxVideoBytes) {
        final stop = rec.dual ? stopDualRecording() : stopRecording(rec.source);
        unawaited(stop.then((_) => onEvent(true, 'Video de ${rec.label} cortado al llegar a 900 MB y guardado')));
      }
    } catch (_) {
      // Un frame dañado no debe tumbar la grabación entera.
    }
  }

  /// Corta la grabación de [src] y la agrega a Multimedia. `null` si no
  /// alcanzó a escribir ningún frame (el archivo vacío se borra).
  Future<MediaItem?> stopRecording(AiCameraSource src) async {
    final rec = _recordings[src];
    if (rec == null || rec.stopping) return null;
    return _finish(rec, () => _recordings.remove(src));
  }

  Future<MediaItem?> _finish(_Recording rec, void Function() unregister) async {
    rec.stopping = true;
    await rec.sub?.cancel();
    await rec.loop;
    await rec.pending;
    final duration = DateTime.now().difference(rec.started);
    unregister();
    if (rec.ia) vision.release();
    if (!anyRecording) {
      _ticker?.cancel();
      _ticker = null;
    }

    final frames = rec.writer.frameCount;
    await rec.writer.close(duration.inMilliseconds);
    if (frames == 0) {
      await deleteMediaFile(rec.writer.path);
      notifyListeners();
      return null;
    }
    final item = MediaItem(
      id: rec.id,
      kind: MediaKind.video,
      source: rec.source,
      filter: rec.filter,
      time: rec.started,
      path: rec.writer.path,
      thumbPath: rec.thumbPath,
      durationMs: duration.inMilliseconds,
      frames: frames,
      sizeBytes: await mediaFileSize(rec.writer.path),
      dual: rec.dual,
      ia: rec.ia,
    );
    items.insert(0, item);
    notifyListeners();
    await _saveIndex();
    return item;
  }

  // ---------------- Video de las 2 cámaras en uno ----------------
  // CAM 1 | CAM 2 lado a lado en un solo AVI (1284×480), cada una con su
  // filtro quemado. CAM 1 aporta el último JPEG de su /stream (como en la
  // grabación normal, mientras su video esté en pantalla) y CAM 2 un frame
  // del reproductor RTSP; si una no tiene imagen sale "SIN SEÑAL" y el video
  // sigue con la otra.

  static const _dualMaxFps = 10;
  _Recording? _dual;
  Uint8List? _dualCam1;
  DateTime _dualCam1At = DateTime(0);
  bool _dualToggling = false;

  bool get isDualRecording => _dual != null;
  bool get isDualToggling => _dualToggling;
  Duration get dualElapsed => _dual == null ? Duration.zero : DateTime.now().difference(_dual!.started);
  bool get dualStalled => _dual != null && DateTime.now().difference(_dual!.lastFrame) > const Duration(seconds: 3);

  Future<String> toggleDualRecording() async {
    if (_dualToggling) return 'Espera…';
    _dualToggling = true;
    notifyListeners();
    try {
      if (_dual != null) {
        final item = await stopDualRecording();
        return item != null ? 'Video CAM 1+2 guardado en Multimedia (${item.durationLabel})' : 'La grabación no alcanzó a guardar ningún frame';
      }
      return await startDualRecording();
    } finally {
      _dualToggling = false;
      notifyListeners();
    }
  }

  Future<String> startDualRecording() async {
    if (_dual != null) return 'Ya se están grabando las 2 cámaras';
    if (!canRecordVideo) return 'Grabar video no está disponible en esta plataforma';
    final ia = vision.iaActive;
    final has1 = camService.isConfigured, has2 = ia || tapoCam.isConfigured;
    if (!has1 && !has2) return 'Ninguna cámara vinculada — agrégalas en Sistema › Conexiones';

    final now = DateTime.now();
    final id = 'shadowbot_dual_${now.millisecondsSinceEpoch}${ia ? '_IA' : ''}';
    final writer = await openAviWriter('$id.avi');
    if (writer == null) return 'No se pudo crear el archivo de video';
    final rec = _Recording(AiCameraSource.esp32cam, writer, id, filterOf(AiCameraSource.esp32cam), dual: true, ia: ia);
    if (ia) vision.acquire();
    _dual = rec;
    _dualCam1 = null;
    if (has1) {
      rec.sub = camService.frames.listen((jpeg) {
        _dualCam1 = jpeg;
        _dualCam1At = DateTime.now();
      });
    }
    rec.loop = _dualLoop(rec, has2 && !ia);
    _ticker ??= Timer.periodic(const Duration(seconds: 1), (_) => notifyListeners());
    notifyListeners();
    final missing = !has1 ? ' (CAM 1 no vinculada)' : (!has2 ? ' (CAM 2 no vinculada)' : '');
    return 'Grabando CAM 1 + CAM 2${ia ? ' (VISIÓN IA)' : ''} en un solo video$missing';
  }

  Future<void> _dualLoop(_Recording rec, bool withCam2) async {
    const minFrame = Duration(milliseconds: 1000 ~/ _dualMaxFps);
    const pw = 640, ph = 480;
    while (!rec.stopping) {
      final sw = Stopwatch()..start();
      final raw = withCam2 ? await tapoCam.captureRaw() : null;
      if (rec.stopping) break;
      // CAM 2 en VISIÓN IA: el último cuadro con recuadros de la PC.
      final iaJpeg = rec.ia && vision.hasFreshFrame() ? vision.frame.value : null;
      // Un JPEG de CAM 1 de hace más de 2 s ya no cuenta (se cortó su video).
      final jpeg = DateTime.now().difference(_dualCam1At) < const Duration(seconds: 2) ? _dualCam1 : null;
      if (raw == null && jpeg == null && iaJpeg == null) {
        await Future.delayed(const Duration(milliseconds: 250));
        continue;
      }
      final job = DualFrameJob(
        cam1: jpeg == null
            ? null
            : FrameJob.jpeg(jpeg, filter: filterOf(AiCameraSource.esp32cam), quarterTurns: kCamRotationQuarterTurns, fitW: pw, fitH: ph),
        cam2: iaJpeg != null
            ? FrameJob.jpeg(iaJpeg, filter: filterOf(AiCameraSource.tapoCam), fitW: pw, fitH: ph)
            : (raw == null
                ? null
                : FrameJob.raw(raw.bytes, width: raw.width, height: raw.height, stride: raw.stride, filter: filterOf(AiCameraSource.tapoCam), fitW: pw, fitH: ph)),
        panelW: pw,
        panelH: ph,
      );
      await _addResult(rec, composeDualAsync(job));
      final left = minFrame - sw.elapsed;
      if (left > Duration.zero) await Future.delayed(left);
    }
  }

  /// Corta el video de las 2 cámaras y lo agrega a Multimedia.
  Future<MediaItem?> stopDualRecording() async {
    final rec = _dual;
    if (rec == null || rec.stopping) return null;
    return _finish(rec, () {
      _dual = null;
      _dualCam1 = null;
    });
  }

  Future<void> delete(MediaItem item) async {
    items.removeWhere((e) => e.id == item.id);
    notifyListeners();
    if (item.path != null) await deleteMediaFile(item.path!);
    if (item.thumbPath != null) await deleteMediaFile(item.thumbPath!);
    await _saveIndex();
  }

  @override
  void dispose() {
    vision.removeListener(_onVisionChanged);
    _ticker?.cancel();
    for (final src in _recordings.keys.toList()) {
      stopRecording(src);
    }
    stopDualRecording();
    super.dispose();
  }
}
