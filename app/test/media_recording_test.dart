import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:inspect_bot_app/services/frame_filter.dart';
import 'package:inspect_bot_app/services/media_files/media_files_io.dart';
import 'package:inspect_bot_app/widgets/camera_filters.dart';

/// Frame de prueba 320x240 (como el QVGA del ESP32-CAM): mitad izquierda
/// roja, derecha azul, y un cuadro blanco arriba a la izquierda para
/// comprobar la rotación.
Uint8List _testJpeg() {
  final im = img.Image(width: 320, height: 240);
  for (final p in im) {
    final white = p.x < 40 && p.y < 40;
    p
      ..r = white ? 255 : (p.x < 160 ? 220 : 20)
      ..g = white ? 255 : 30
      ..b = white ? 255 : (p.x < 160 ? 20 : 220);
  }
  return img.encodeJpg(im, quality: 95);
}

void main() {
  test('jpegSize lee el SOF', () {
    expect(jpegSize(_testJpeg()), (320, 240));
  });

  test('rotación 3 (= RotatedBox 270°): esquina blanca pasa a abajo-izquierda', () {
    final r = processFrame(FrameJob.jpeg(_testJpeg(), filter: CameraFilterMode.none, quarterTurns: 3))!;
    expect((r.width, r.height), (240, 320));
    final out = img.decodeJpg(r.jpeg)!;
    final bl = out.getPixel(10, 310);
    expect(bl.r > 200 && bl.g > 200 && bl.b > 200, isTrue, reason: 'abajo-izq debe ser blanco');
    final tl = out.getPixel(10, 10);
    expect(tl.b > 150 && tl.r < 80, isTrue, reason: 'arriba-izq debe ser azul (era la derecha)');
  });

  test('filtro visión nocturna deja la imagen verde', () {
    final r = processFrame(FrameJob.jpeg(_testJpeg(), filter: CameraFilterMode.nightVision))!;
    final p = img.decodeJpg(r.jpeg)!.getPixel(100, 120);
    expect(p.g > p.r && p.g > p.b, isTrue);
  });

  test('filtro B/N deja r=g=b', () {
    final r = processFrame(FrameJob.jpeg(_testJpeg(), filter: CameraFilterMode.blackWhite))!;
    final p = img.decodeJpg(r.jpeg)!.getPixel(100, 120);
    expect((p.r - p.g).abs() < 8 && (p.g - p.b).abs() < 8, isTrue);
  });

  test('raw BGR0 (Tapo) con reescalado', () {
    const w = 1920, h = 1080, stride = w * 4;
    final raw = Uint8List(stride * h);
    for (var i = 0; i < raw.length; i += 4) {
      raw[i] = 200; // B
      raw[i + 1] = 10; // G
      raw[i + 2] = 10; // R
    }
    final r = processFrame(FrameJob.raw(raw, width: w, height: h, stride: stride, filter: CameraFilterMode.military, maxSide: 960))!;
    expect((r.width, r.height), (960, 540));
  });

  test('AVI MJPEG', () async {
    final dir = Directory(Platform.environment['AVI_OUT'] ?? Directory.systemTemp.createTempSync('avi').path)..createSync(recursive: true);
    for (final f in CameraFilterMode.values) {
      final w = await openAviWriterAt('${dir.path}/test_${f.name}.avi');
      for (var i = 0; i < 25; i++) {
        final r = processFrame(FrameJob.jpeg(_testJpeg(), filter: f, quarterTurns: 3, quality: 80))!;
        await w.addFrame(r.jpeg, r.width, r.height);
      }
      await w.close(2500); // 25 frames en 2.5 s = 10 fps
      expect(w.frameCount, 25);
      expect(File(w.path).lengthSync(), w.bytesWritten + 8 + 25 * 16);
    }
  });
}
