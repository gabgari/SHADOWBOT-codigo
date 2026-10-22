import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:inspect_bot_app/services/vision_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// PC de visión de mentira: /salud, /modo, /modo?m=, /estado.
class FakeVisionPc {
  late final HttpServer server;
  String modo = 'inspeccion';
  Map<String, int> conteo = {'fisura': 1, 'persona': 2};
  final modos = ['fuego', 'seguridad', 'inspeccion', 'todo'];

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) {
      final r = req.response..headers.contentType = ContentType.json;
      switch (req.uri.path) {
        case '/salud':
          r.write(jsonEncode({'ok': true}));
        case '/modo':
          final m = req.uri.queryParameters['m'];
          if (m != null && !modos.contains(m)) {
            r.statusCode = 400;
          } else {
            if (m != null) modo = m;
            r.write(jsonEncode({'modo': modo, 'modos': modos}));
          }
        case '/estado':
          r.write(jsonEncode({
            'camara': true,
            'modo': modo,
            'fuego': false,
            'conteo': conteo,
            'detecciones': [
              {'clase': 'person', 'etiqueta': 'Persona', 'categoria': 'persona', 'confianza': 0.89, 'caja': [670, 380, 810, 880]},
            ],
            'fps': 5.1,
          }));
        default:
          r.statusCode = 404;
      }
      r.close();
    });
  }

  String get host => '127.0.0.1:${server.port}';
}

void main() {
  // Sin TestWidgetsFlutterBinding: con él, todo HTTP devuelve 400 falso.
  test('modos, conteo y avisos discretos de la PC de visión', () async {
    SharedPreferences.setMockInitialValues({});
    final pc = FakeVisionPc();
    await pc.start();
    final v = VisionService();
    final notices = <VisionNotice>[];
    final sub = v.notices.listen(notices.add);

    await v.setHost(pc.host);
    expect(v.available, isTrue);
    await v.setUseIa(true);
    expect(v.iaActive, isTrue);

    // Al entrar a IA lee /modo y luego /estado cada segundo.
    await Future.delayed(const Duration(milliseconds: 1600));
    expect(v.modo, 'inspeccion');
    expect(v.conteo, {'fisura': 1, 'persona': 2});
    expect(v.detections.single.etiqueta, 'Persona');
    expect(v.fire, isFalse);
    // En INSPECCIÓN avisa la fisura, no la persona.
    expect(notices.where((n) => n.soft).map((n) => n.text).toList(), [contains('Fisura')]);

    // Cambio desde la app.
    expect(await v.setModo('seguridad'), isNull);
    expect(v.modo, 'seguridad');
    expect(pc.modo, 'seguridad');
    expect(await v.setModo('nada'), contains('no acepta'));

    // Cambio desde otro lado (Telegram / la PC): se refleja por /estado.
    pc.modo = 'todo';
    await Future.delayed(const Duration(milliseconds: 1300));
    expect(v.modo, 'todo');

    await sub.cancel();
    v.dispose();
    await pc.server.close(force: true);
  });
}
