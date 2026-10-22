import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:inspect_bot_app/services/vision_service.dart';

/// "JPEG" falso: FFD8 + datos (que incluyen \r\n\r\n y FFD9 sueltos) + FFD9.
Uint8List fakeJpeg(int n, int seed) {
  final r = Random(seed);
  final body = List<int>.generate(n, (_) => r.nextInt(256));
  body.setRange(10, 14, const [13, 10, 13, 10]);
  return Uint8List.fromList([0xFF, 0xD8, ...body, 0xFF, 0xD9]);
}

List<int> multipart(List<Uint8List> jpegs, {bool withLength = true}) {
  final out = <int>[];
  for (final j in jpegs) {
    out.addAll(latin1.encode('--frame\r\nContent-Type: image/jpeg\r\n${withLength ? 'Content-Length: ${j.length}\r\n' : ''}\r\n'));
    out.addAll(j);
    out.addAll(latin1.encode('\r\n'));
  }
  return out;
}

void main() {
  test('separa los JPEG por Content-Length aunque lleguen en pedazos', () {
    final jpegs = [for (var i = 0; i < 6; i++) fakeJpeg(3000 + i * 997, i)];
    final bytes = multipart(jpegs);
    final got = <Uint8List>[];
    final p = MjpegPartParser(got.add);
    final r = Random(1);
    var i = 0;
    while (i < bytes.length) {
      final n = 1 + r.nextInt(1500);
      p.add(bytes.sublist(i, min(i + n, bytes.length)));
      i += n;
    }
    expect(got.length, jpegs.length);
    for (var k = 0; k < jpegs.length; k++) {
      expect(got[k], jpegs[k]);
    }
  });

  test('sin Content-Length usa las marcas FFD8/FFD9', () {
    // Sin largo, el cuerpo no puede traer FFD9 suelto (como un JPEG real).
    Uint8List clean(int n, int seed) {
      final j = fakeJpeg(n, seed);
      for (var k = 2; k < j.length - 2; k++) {
        if (j[k] == 0xFF) j[k] = 0xFE;
      }
      return j;
    }

    final jpegs = [clean(2000, 7), clean(2500, 8), clean(1800, 9)];
    final got = <Uint8List>[];
    final p = MjpegPartParser(got.add);
    final bytes = multipart(jpegs, withLength: false);
    for (var i = 0; i < bytes.length; i += 333) {
      p.add(bytes.sublist(i, min(i + 333, bytes.length)));
    }
    expect(got, jpegs);
  });
}
