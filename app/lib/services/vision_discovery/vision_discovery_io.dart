import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

/// Escucha un puerto UDP de anuncios (broadcast) mientras la app está
/// abierta. Lo usan la PC de visión (5001) y las placas CONTROL / SENSORES
/// (4210). Cada paquete se entrega como texto con la IP de quien lo mandó.
///
/// En Android muchos teléfonos tiran los broadcast si nadie tiene un
/// `WifiManager.MulticastLock`: MainActivity lo toma/suelta por el canal
/// "shadowbot/net" (uno solo para todos los escuchadores: se suelta cuando
/// se cierra el último). En iOS, sin el entitlement de multicast puede no
/// llegar nada; entonces quedan las IPs manuales.
class UdpAnnounceListener {
  static const _net = MethodChannel('shadowbot/net');
  static int _lockUsers = 0;

  final int port;
  final void Function(String text, String fromIp) onPacket;
  UdpAnnounceListener({required this.port, required this.onPacket});

  RawDatagramSocket? _socket;
  StreamSubscription<RawSocketEvent>? _sub;
  Timer? _retry;
  bool _stopped = false;
  bool _holdsLock = false;

  bool get listening => _socket != null;

  Future<void> start() async {
    _stopped = false;
    if (_socket != null) return;
    if (!_holdsLock) {
      _holdsLock = true;
      if (_lockUsers++ == 0) await _invoke('multicastLock');
    }
    try {
      final s = await RawDatagramSocket.bind(InternetAddress.anyIPv4, port, reuseAddress: true);
      if (_stopped) {
        s.close();
        return;
      }
      s.broadcastEnabled = true;
      _socket = s;
      _sub = s.listen((ev) {
        if (ev != RawSocketEvent.read) return;
        final d = s.receive();
        if (d == null) return;
        try {
          onPacket(utf8.decode(d.data, allowMalformed: true), d.address.address);
        } catch (_) {}
      }, onError: (_) => _restart(), onDone: _restart);
    } catch (_) {
      // Puerto ocupado / sin red: reintenta en un rato.
      _restart();
    }
  }

  void _restart() {
    _closeSocket();
    if (_stopped) return;
    _retry?.cancel();
    _retry = Timer(const Duration(seconds: 5), start);
  }

  void _closeSocket() {
    _sub?.cancel();
    _sub = null;
    _socket?.close();
    _socket = null;
  }

  Future<void> stop() async {
    _stopped = true;
    _retry?.cancel();
    _retry = null;
    _closeSocket();
    if (_holdsLock) {
      _holdsLock = false;
      if (--_lockUsers == 0) await _invoke('multicastUnlock');
    }
  }

  static Future<void> _invoke(String method) async {
    try {
      if (Platform.isAndroid) await _net.invokeMethod(method);
    } catch (_) {}
  }
}

/// Anuncio de la PC de visión: cada 2 s manda por UDP broadcast al puerto
/// 5001 `{"servicio": "detector_fuego", "url": "http://IP:5000"}`. Cada
/// `url` recibida se pasa a [onFound] (VisionService decide si cambia).
class VisionDiscovery {
  static const defaultPort = 5001;

  final void Function(String url) onFound;

  /// Puerto del anuncio (5001; otro solo en los tests).
  final int port;
  late final UdpAnnounceListener _udp;

  VisionDiscovery({required this.onFound, this.port = defaultPort}) {
    _udp = UdpAnnounceListener(port: port, onPacket: (text, _) => _onPacket(text));
  }

  bool get listening => _udp.listening;
  Future<void> start() => _udp.start();
  Future<void> stop() => _udp.stop();

  void _onPacket(String text) {
    try {
      final j = jsonDecode(text);
      if (j is! Map || j['servicio'] != 'detector_fuego') return;
      final url = j['url'];
      if (url is String && url.trim().isNotEmpty) onFound(url.trim());
    } catch (_) {
      // Otro programa en el mismo puerto: se ignora.
    }
  }
}

/// Anuncio de las placas: CONTROL manda "SHADOWBOT-CONTROL" y SENSORES
/// `SHADOWBOT-SENSORES <ip de control>` cada 3 s por broadcast al 4210 (ya
/// estaba en el firmware para la placa CAMARA; no hay que reflashear nada).
class BoardDiscovery {
  static const defaultPort = 4210;

  /// [board] = 'control' | 'sensores'; [ip] = quien lo mandó;
  /// [controlIp] = la IP de CONTROL que conoce SENSORES (o null).
  final void Function(String board, String ip, String? controlIp) onFound;
  late final UdpAnnounceListener _udp;

  BoardDiscovery({required this.onFound, int port = defaultPort}) {
    _udp = UdpAnnounceListener(port: port, onPacket: _onPacket);
  }

  bool get listening => _udp.listening;
  Future<void> start() => _udp.start();
  Future<void> stop() => _udp.stop();

  void _onPacket(String text, String ip) {
    final t = text.trim();
    if (t.startsWith('SHADOWBOT-CONTROL')) {
      onFound('control', ip, null);
    } else if (t.startsWith('SHADOWBOT-SENSORES')) {
      final parts = t.split(RegExp(r'\s+'));
      final c = parts.length > 1 && parts[1] != '-' ? parts[1] : null;
      onFound('sensores', ip, c);
    }
  }
}
