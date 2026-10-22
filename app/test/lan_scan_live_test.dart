import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:inspect_bot_app/services/lan_scan/lan_scan_io.dart';

/// Prueba REAL en la red de esta máquina (no corre si no se pide):
///   LAN_LIVE=1 RTSP_URL=rtsp://usuario:clave@IP:554/stream2 flutter test test/lan_scan_live_test.dart
void main() {
  final live = Platform.environment['LAN_LIVE'] != null;
  test('busca cámaras RTSP (554) y comprueba usuario/clave', () async {
    final sw = Stopwatch()..start();
    final found = await scanLanForPort(554);
    // ignore: avoid_print
    print('Equipos con RTSP: $found (${sw.elapsedMilliseconds} ms)');
    final base = Uri.parse(Platform.environment['RTSP_URL'] ?? 'rtsp://usuario:clave@0.0.0.0:554/stream2');
    for (final ip in found) {
      final ok = await rtspCredentialsOk(base.replace(host: ip));
      // ignore: avoid_print
      print('  $ip -> ${ok == true ? 'ACEPTA la clave' : ok == false ? 'rechaza la clave' : 'no responde RTSP'}');
    }
  }, skip: live ? false : 'Define LAN_LIVE=1 para buscar en la red real', timeout: const Timeout(Duration(minutes: 1)));
}
