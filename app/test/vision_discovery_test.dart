import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:inspect_bot_app/services/vision_discovery/vision_discovery_io.dart';

void main() {
  test('toma la url del anuncio UDP de la PC de visión e ignora lo demás', () async {
    final found = Completer<String>();
    final got = <String>[];
    // En esta PC de desarrollo el 5001 lo ocupa un servicio de Windows; en el
    // teléfono se usa el 5001 de verdad.
    final d = VisionDiscovery(port: 45001, onFound: (u) {
      got.add(u);
      if (!found.isCompleted) found.complete(u);
    });
    await d.start();
    expect(d.listening, isTrue);

    final tx = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    tx.broadcastEnabled = true;
    // Basura y otro servicio: no cuentan.
    tx.send(utf8.encode('hola'), InternetAddress.loopbackIPv4, d.port);
    tx.send(utf8.encode(jsonEncode({'servicio': 'otro', 'url': 'http://1.2.3.4:9'})), InternetAddress.loopbackIPv4, d.port);
    tx.send(utf8.encode(jsonEncode({'servicio': 'detector_fuego', 'url': 'http://192.168.3.54:5000'})), InternetAddress.loopbackIPv4, d.port);

    expect(await found.future.timeout(const Duration(seconds: 3)), 'http://192.168.3.54:5000');
    expect(got, ['http://192.168.3.54:5000']);
    tx.close();
    await d.stop();
    expect(d.listening, isFalse);
  });

  test('toma las IPs que anuncian CONTROL y SENSORES (puerto 4210)', () async {
    final got = <String>[];
    final d = BoardDiscovery(port: 45003, onFound: (b, ip, c) => got.add('$b $ip ${c ?? '-'}'));
    await d.start();
    final tx = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    tx.send(utf8.encode('SHADOWBOT-CONTROL'), InternetAddress.loopbackIPv4, 45003);
    tx.send(utf8.encode('SHADOWBOT-SENSORES 192.168.43.20'), InternetAddress.loopbackIPv4, 45003);
    tx.send(utf8.encode('SHADOWBOT-SENSORES -'), InternetAddress.loopbackIPv4, 45003);
    tx.send(utf8.encode('otra cosa'), InternetAddress.loopbackIPv4, 45003);
    await Future.delayed(const Duration(milliseconds: 500));
    expect(got, ['control 127.0.0.1 -', 'sensores 127.0.0.1 192.168.43.20', 'sensores 127.0.0.1 -']);
    tx.close();
    await d.stop();
  });
}
