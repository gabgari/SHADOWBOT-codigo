import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:inspect_bot_app/services/vision_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Prueba REAL contra el detector (detectar_fuego.py) corriendo. Solo se
/// ejecuta si se da la dirección:
///   VISION_HOST=127.0.0.1:5000 flutter test test/vision_live_test.dart
void main() {
  final host = Platform.environment['VISION_HOST'];

  test('la app habla con el detector real: salud, modo, estado y video', () async {
    SharedPreferences.setMockInitialValues({});
    final v = VisionService();
    await v.setHost(host!);
    expect(v.available, isTrue, reason: '/salud + camara');
    expect(await v.setUseIa(true).then((_) => v.iaActive), isTrue);

    // /modo
    expect(await v.getModo(), isNotNull);
    expect(v.modos, containsAll(['fuego', 'seguridad', 'inspeccion', 'todo']));
    expect(await v.setModo('fuego'), isNull);
    expect(v.modo, 'fuego');
    expect(await v.setModo('inexistente'), isNotNull); // 400 del servidor

    // Video MJPEG por el mismo lector que usa la app.
    var frames = 0;
    final sub = v.frames.listen((_) => frames++);
    v.acquire();
    await Future.delayed(const Duration(seconds: 6));
    v.release();
    await sub.cancel();
    final fps = frames / 6;
    // ignore: avoid_print
    print('Video recibido: $frames cuadros en 6 s (${fps.toStringAsFixed(1)} fps) · IA ${v.fps} fps · modo ${v.modo} · conteo ${v.conteo} · cámara ${v.cameraIp}');
    expect(frames, greaterThan(20), reason: 'el video debe salir fluido');
    expect(v.fps, isNotNull);

    await v.setModo('seguridad');
    v.dispose();
  }, skip: host == null ? 'Define VISION_HOST para probar contra el detector real' : false, timeout: const Timeout(Duration(minutes: 2)));
}
