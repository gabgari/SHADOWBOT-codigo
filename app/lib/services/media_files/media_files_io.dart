import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:path_provider/path_provider.dart';

import 'avi_writer.dart';

/// Todo queda junto en una carpeta `ShadowBot/` dentro del almacenamiento
/// de la app (Android/iOS/Windows/Linux/macOS), con un `multimedia.json`
/// que indexa fotos y videos para que la sección Multimedia los recupere al
/// volver a abrir la app.
const bool mediaFilesPersistent = true;

Future<Directory> _folder() async {
  Directory baseDir;
  try {
    baseDir = await getDownloadsDirectory() ?? await getApplicationDocumentsDirectory();
  } catch (_) {
    baseDir = await getApplicationDocumentsDirectory();
  }
  final folder = Directory('${baseDir.path}/ShadowBot');
  if (!await folder.exists()) await folder.create(recursive: true);
  return folder;
}

Future<String?> writeMediaBytes(String filename, Uint8List bytes) async {
  final file = File('${(await _folder()).path}/$filename');
  await file.writeAsBytes(bytes, flush: true);
  return file.path;
}

Future<String?> readMediaIndex() async {
  final file = File('${(await _folder()).path}/multimedia.json');
  if (!await file.exists()) return null;
  return file.readAsString();
}

Future<void> writeMediaIndex(String json) async {
  final folder = await _folder();
  // Escribe a un temporal y renombra: si la app se cierra a la mitad no
  // queda un índice cortado (y con él, toda la galería "perdida").
  final tmp = File('${folder.path}/multimedia.json.tmp');
  await tmp.writeAsString(json, flush: true);
  await tmp.rename('${folder.path}/multimedia.json');
}

Future<bool> mediaFileExists(String path) => File(path).exists();

Future<void> deleteMediaFile(String path) async {
  final f = File(path);
  if (await f.exists()) await f.delete();
}

Future<int> mediaFileSize(String path) async {
  final f = File(path);
  return await f.exists() ? f.length() : 0;
}

/// Imagen de un archivo guardado (foto o miniatura de video).
ImageProvider? mediaImageProvider(String path) => FileImage(File(path));

Future<AviWriter?> openAviWriter(String filename) async => openAviWriterAt('${(await _folder()).path}/$filename');

/// Igual que [openAviWriter] pero con ruta completa (lo usan las pruebas).
Future<AviWriter> openAviWriterAt(String path) async => _IoAviWriter(path, await File(path).open(mode: FileMode.write));

class _IoAviWriter implements AviWriter {
  @override
  final String path;
  final RandomAccessFile _raf;
  _IoAviWriter(this.path, this._raf);

  // Ver el mapa de offsets en [_header]. Los frames empiezan en 224.
  static const _headerSize = 224;
  static const _moviFourccPos = 220;

  int _width = 0, _height = 0;
  int _pos = 0;
  int _maxFrame = 0;
  final _index = <int>[]; // pares (offset relativo a 'movi', tamaño)
  bool _closed = false;

  @override
  int get frameCount => _index.length ~/ 2;

  @override
  int get bytesWritten => _pos;

  @override
  Future<void> addFrame(Uint8List jpeg, int width, int height) async {
    if (_closed) return;
    if (_pos == 0) {
      _width = width;
      _height = height;
      await _raf.writeFrom(_header(frames: 0, durationMs: 0, moviBytes: 0, fileSize: 0));
      _pos = _headerSize;
    }
    final pad = jpeg.length.isOdd ? 1 : 0;
    final head = ByteData(8)
      ..setUint32(0, _fourcc('00dc'), Endian.little)
      ..setUint32(4, jpeg.length, Endian.little);
    _index
      ..add(_pos - _moviFourccPos)
      ..add(jpeg.length);
    await _raf.writeFrom(head.buffer.asUint8List());
    await _raf.writeFrom(jpeg);
    if (pad == 1) await _raf.writeByte(0);
    _pos += 8 + jpeg.length + pad;
    if (jpeg.length > _maxFrame) _maxFrame = jpeg.length;
  }

  @override
  Future<void> close(int durationMs) async {
    if (_closed) return;
    _closed = true;
    if (_pos == 0) {
      await _raf.close();
      return;
    }
    final moviBytes = _pos - _moviFourccPos; // 'movi' + chunks
    final n = frameCount;
    final idx = ByteData(8 + n * 16)
      ..setUint32(0, _fourcc('idx1'), Endian.little)
      ..setUint32(4, n * 16, Endian.little);
    for (var i = 0; i < n; i++) {
      final o = 8 + i * 16;
      idx
        ..setUint32(o, _fourcc('00dc'), Endian.little)
        ..setUint32(o + 4, 0x10, Endian.little) // AVIIF_KEYFRAME: en MJPEG todos lo son
        ..setUint32(o + 8, _index[i * 2], Endian.little)
        ..setUint32(o + 12, _index[i * 2 + 1], Endian.little);
    }
    await _raf.writeFrom(idx.buffer.asUint8List());
    final fileSize = _pos + idx.lengthInBytes;
    await _raf.setPosition(0);
    await _raf.writeFrom(_header(frames: n, durationMs: durationMs, moviBytes: moviBytes, fileSize: fileSize));
    await _raf.flush();
    await _raf.close();
  }

  /// RIFF 'AVI ' > LIST 'hdrl' (avih + LIST 'strl' (strh + strf)) > LIST 'movi'.
  Uint8List _header({required int frames, required int durationMs, required int moviBytes, required int fileSize}) {
    final b = ByteData(_headerSize);
    void u32(int o, int v) => b.setUint32(o, v, Endian.little);
    void u16(int o, int v) => b.setUint16(o, v, Endian.little);
    void cc(int o, String s) => u32(o, _fourcc(s));

    // fps real como fracción exacta: rate/scale = frames / segundos.
    final safeMs = durationMs > 0 ? durationMs : 1000;
    final rate = frames > 0 ? frames * 1000 : 10;
    final scale = frames > 0 ? safeMs : 1;
    final usPerFrame = frames > 0 ? (safeMs * 1000 / frames).round() : 100000;

    cc(0, 'RIFF');
    u32(4, fileSize > 8 ? fileSize - 8 : 0);
    cc(8, 'AVI ');
    cc(12, 'LIST');
    u32(16, 192);
    cc(20, 'hdrl');
    cc(24, 'avih');
    u32(28, 56);
    u32(32, usPerFrame);
    u32(36, frames > 0 ? (_maxFrame * 1000000 / usPerFrame).round() : 0);
    u32(44, 0x10 | 0x100); // AVIF_HASINDEX | AVIF_ISINTERLEAVED
    u32(48, frames);
    u32(56, 1);
    u32(60, _maxFrame + 8);
    u32(64, _width);
    u32(68, _height);
    cc(88, 'LIST');
    u32(92, 116);
    cc(96, 'strl');
    cc(100, 'strh');
    u32(104, 56);
    cc(108, 'vids');
    cc(112, 'MJPG');
    u32(128, scale);
    u32(132, rate);
    u32(140, frames);
    u32(144, _maxFrame + 8);
    u32(148, 0xFFFFFFFF);
    u16(160, _width);
    u16(162, _height);
    cc(164, 'strf');
    u32(168, 40);
    u32(172, 40);
    u32(176, _width);
    u32(180, _height);
    u16(184, 1);
    u16(186, 24);
    cc(188, 'MJPG');
    u32(192, _width * _height * 3);
    cc(212, 'LIST');
    u32(216, moviBytes);
    cc(220, 'movi');
    return b.buffer.asUint8List();
  }

  static int _fourcc(String s) =>
      s.codeUnitAt(0) | (s.codeUnitAt(1) << 8) | (s.codeUnitAt(2) << 16) | (s.codeUnitAt(3) << 24);
}
