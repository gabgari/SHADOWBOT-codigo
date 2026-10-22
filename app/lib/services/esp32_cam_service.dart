import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../models/node_link.dart';
import 'device_config.dart';

/// Cliente para el nodo de video (ESP32-CAM / ESP32-S3 con cámara).
///
/// Las rutas usadas aquí son EXACTAMENTE las que expone el firmware ya
/// escrito en `firmware/CAMARA/CAMARA.ino` (carpeta raíz del proyecto):
///   GET /             (puerto 80) -> página de bienvenida
///   GET /viewer       (puerto 80) -> visor HTML con <img> apuntando a /stream
///   GET /capture      (puerto 80) -> una foto JPEG suelta
///   GET /stream       (puerto 81) -> multipart/x-mixed-replace (MJPEG) en vivo
///
/// El stream vive en su PROPIO servidor (puerto 81): el servidor HTTP del
/// ESP32 corre en un solo hilo, y el handler de /stream nunca vuelve
/// mientras el cliente siga conectado — si compartiera puerto con
/// /capture, una captura pedida durante el streaming se quedaría
/// esperando ese hilo (o llegaba corrupta). Con dos servidores, /capture
/// siempre se atiende al toque sin importar si el stream está activo.
///
/// *** VINCULACIÓN PENDIENTE ***
/// Falta: cargar aquí la IP real que imprime el ESP32-CAM por Serial /
/// Telegram (`sendTelegram` en el .ino), guardarla desde
/// Sistema > Conexiones (ver `DeviceConfig`) y, opcionalmente, resolverla
/// automáticamente (mDNS / respuesta al comando `/ip` del bot de Telegram)
/// en vez de escribirla a mano.
class Esp32CamService {
  final DeviceConfig config;
  Esp32CamService(this.config);

  String get _host => config.of(HardwareNode.esp32cam).host;

  /// Cada JPEG que llega por /stream mientras algún `MjpegView` lo está
  /// mostrando. El ESP32-CAM solo atiende un /stream a la vez, así que la
  /// grabación de video (ver `MediaLibrary`) se cuelga de los frames del
  /// visor en vez de abrir una segunda conexión.
  final _frames = StreamController<Uint8List>.broadcast();
  Stream<Uint8List> get frames => _frames.stream;
  void pushFrame(Uint8List jpeg) {
    if (_frames.hasListener) _frames.add(jpeg);
  }

  bool get isConfigured => _host.isNotEmpty;

  Uri? _uri(String path, {int port = 80}) {
    if (!isConfigured) return null;
    return Uri.parse('http://$_host:$port$path');
  }

  Uri? get streamUri => _uri('/stream', port: 81);
  Uri? get captureUri => _uri('/capture');
  Uri? get viewerUri => _uri('/viewer');

  /// Verifica que el ESP32-CAM responda antes de intentar el stream.
  /// TODO(vinculación): reemplazar/():complementar con un ping periódico
  /// (Timer) desde NodosScreen / SistemaScreen una vez el hardware esté
  /// físicamente en la red.
  Future<bool> checkReachable() async {
    final uri = _uri('/');
    if (uri == null) return false;
    try {
      final res = await http.get(uri).timeout(const Duration(seconds: 3));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Estado del sensor de la cámara (`/estado`, firmware nuevo):
  /// `null` = no responde; `(cam: false, err: '0x105')` = la placa está en
  /// la red pero la cámara no arrancó (flex flojo, PSRAM apagada…).
  /// Firmware viejo sin /estado: se toma como cámara bien si "/" responde.
  Future<({bool cam, String err, bool psram})?> getStatus() async {
    final uri = _uri('/estado');
    if (uri == null) return null;
    try {
      final res = await http.get(uri).timeout(const Duration(seconds: 3));
      if (res.statusCode == 200 && res.body.trimLeft().startsWith('{')) {
        final j = jsonDecode(res.body) as Map<String, dynamic>;
        return (cam: j['cam'] == true, err: '${j['err'] ?? ''}', psram: j['psram'] == true);
      }
      return await checkReachable() ? (cam: true, err: '', psram: true) : null;
    } catch (_) {
      return null;
    }
  }

  /// Descarga una foto puntual desde /capture.
  /// TODO(vinculación): sin esto conectado, la pantalla Cámara usa una
  /// ilustración de relleno (ver widgets/corridor_placeholder.dart).
  Future<List<int>?> capture() async {
    final uri = captureUri;
    if (uri == null) return null;
    try {
      final res = await http.get(uri).timeout(const Duration(seconds: 6));
      if (res.statusCode == 200) return res.bodyBytes;
      return null;
    } catch (_) {
      return null;
    }
  }
}
