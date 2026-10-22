import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// IPs de la red local (cada /24 donde está el teléfono: Wi-Fi o su propio
/// hotspot) que tienen abierto [port]. Se salta los datos móviles y las VPN.
/// Tarda ~2-3 s por red (48 conexiones a la vez, 400 ms cada una).
Future<List<String>> scanLanForPort(int port, {Duration timeout = const Duration(milliseconds: 400)}) async {
  final List<NetworkInterface> ifaces;
  try {
    ifaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
  } catch (_) {
    return const [];
  }
  const skip = ['rmnet', 'ccmni', 'pdp', 'v4-', 'dummy', 'tun', 'ppp', 'clat', 'lo'];
  final own = <String>{};
  final prefixes = <String>{};
  for (final i in ifaces) {
    final name = i.name.toLowerCase();
    if (skip.any(name.startsWith)) continue;
    for (final a in i.addresses) {
      final ip = a.address;
      if (a.isLoopback || ip.startsWith('169.254.') || !_isPrivate(ip)) continue;
      own.add(ip);
      prefixes.add(ip.substring(0, ip.lastIndexOf('.')));
    }
  }
  final hosts = [
    for (final p in prefixes)
      for (var n = 1; n < 255; n++)
        if (!own.contains('$p.$n')) '$p.$n',
  ];
  final found = <String>[];
  var next = 0;
  Future<void> worker() async {
    while (next < hosts.length) {
      final h = hosts[next++];
      try {
        final s = await Socket.connect(h, port, timeout: timeout);
        s.destroy();
        found.add(h);
      } catch (_) {}
    }
  }

  await Future.wait(List.generate(48, (_) => worker()));
  return found;
}

bool _isPrivate(String ip) {
  final p = ip.split('.').map(int.tryParse).toList();
  if (p.length != 4 || p.contains(null)) return false;
  return p[0] == 192 && p[1] == 168 || p[0] == 10 || (p[0] == 172 && p[1]! >= 16 && p[1]! <= 31);
}

/// ¿La cámara RTSP de [url] acepta su usuario y clave? Hace un DESCRIBE
/// (el mismo saludo que VLC o mpv) con autenticación Digest o Basic, sin
/// abrir video. `true` = acepta, `false` = credenciales rechazadas, `null` =
/// no responde como RTSP. Sirve para no confundir la Tapo del carrito con
/// otra cámara de la casa que también tenga el puerto 554.
Future<bool?> rtspCredentialsOk(Uri url, {Duration timeout = const Duration(seconds: 4)}) async {
  final port = url.hasPort ? url.port : 554;
  final user = Uri.decodeComponent(url.userInfo.split(':').first);
  final pass = url.userInfo.contains(':') ? Uri.decodeComponent(url.userInfo.substring(url.userInfo.indexOf(':') + 1)) : '';
  final plain = url.replace(userInfo: '').toString();

  Future<String?> request(int cseq, String? auth) async {
    Socket? s;
    try {
      s = await Socket.connect(url.host, port, timeout: timeout);
      const nl = '\r\n';
      s.write('DESCRIBE $plain RTSP/1.0${nl}CSeq: $cseq${nl}Accept: application/sdp${nl}User-Agent: SHADOWBOT$nl'
          '${auth == null ? '' : 'Authorization: $auth$nl'}$nl');
      await s.flush();
      final buf = StringBuffer();
      await for (final chunk in s.timeout(timeout)) {
        buf.write(latin1.decode(chunk, allowInvalid: true));
        if (buf.toString().contains('$nl$nl')) break;
      }
      return buf.toString();
    } catch (_) {
      return null;
    } finally {
      s?.destroy();
    }
  }

  int? status(String? r) => r == null ? null : int.tryParse(RegExp(r'^RTSP/1\.\d (\d{3})').firstMatch(r)?.group(1) ?? '');

  final first = await request(1, null);
  final st = status(first);
  if (st == null) return null;
  if (st == 200) return true;
  if (st != 401) return false;

  String? header(String name) {
    for (final line in first!.split('\r\n')) {
      if (line.toLowerCase().startsWith('www-authenticate:') && line.toLowerCase().contains(name)) return line.substring(17).trim();
    }
    return null;
  }

  String? auth;
  final digest = header('digest');
  if (digest != null) {
    String? param(String k) => RegExp('$k="([^"]*)"').firstMatch(digest)?.group(1);
    final realm = param('realm') ?? '';
    final nonce = param('nonce') ?? '';
    String md5hex(String v) => md5.convert(utf8.encode(v)).toString();
    final ha1 = md5hex('$user:$realm:$pass');
    final ha2 = md5hex('DESCRIBE:$plain');
    final qop = param('qop');
    if (qop != null && qop.split(',').map((e) => e.trim()).contains('auth')) {
      const nc = '00000001';
      final cnonce = md5hex(DateTime.now().microsecondsSinceEpoch.toString()).substring(0, 16);
      final resp = md5hex('$ha1:$nonce:$nc:$cnonce:auth:$ha2');
      auth = 'Digest username="$user", realm="$realm", nonce="$nonce", uri="$plain", qop=auth, nc=$nc, cnonce="$cnonce", response="$resp"';
    } else {
      final resp = md5hex('$ha1:$nonce:$ha2');
      auth = 'Digest username="$user", realm="$realm", nonce="$nonce", uri="$plain", response="$resp"';
    }
  } else if (header('basic') != null) {
    auth = 'Basic ${base64.encode(utf8.encode('$user:$pass'))}';
  } else {
    return false;
  }
  final second = status(await request(2, auth));
  if (second == null) return null;
  return second == 200;
}
