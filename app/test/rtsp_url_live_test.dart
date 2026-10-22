import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:inspect_bot_app/services/lan_scan/lan_scan_io.dart';

/// RTSP_URL=rtsp://usuario:clave@IP:554/stream2 flutter test test/rtsp_url_live_test.dart
void main() {
  final url = Platform.environment['RTSP_URL'];
  test('la URL RTSP responde y acepta la clave', () async {
    final ok = await rtspCredentialsOk(Uri.parse(url!));
    // ignore: avoid_print
    print('RESULTADO: ${ok == true ? 'ACEPTA' : ok == false ? 'RECHAZA' : 'NO RESPONDE (otra red / apagada)'}');
  }, skip: url == null ? 'Define RTSP_URL' : false);
}
