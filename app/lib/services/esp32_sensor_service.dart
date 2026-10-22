import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/node_link.dart';
import 'device_config.dart';

/// Lectura cruda esperada desde el ESP32 de sensores.
class SensorPayload {
  final double mq2;
  SensorPayload({required this.mq2});

  factory SensorPayload.fromJson(Map<String, dynamic> j) => SensorPayload(
        mq2: (j['mq2'] as num?)?.toDouble() ?? 0,
      );
}

/// Cliente para la placa de sensores (ESP32 clásico o la ESP8266 de
/// reemplazo) que agrupa el sensor MQ-2 y los 4 LEDs. El carrito ya no
/// lleva sensor de distancia.
///
/// El firmware de este nodo está en `firmware/SENSORES/SENSORES.ino` (raíz
/// del repo) y expone:
///
///   GET /sensors                       -> {"mq2":12.0}
///   GET /led?n=<1-4|all>&state=on|off  -> LEDs (movidos aquí desde CONTROL)
///   GET /ledseq?n=<1-4>&linked=<0|1>   -> excluye/incluye un LED del barrido
///                                          "auto increíble" que corre solo
///                                          mientras el sistema no se ha
///                                          "Iniciado" (ver AppState)
///   GET /ledseq?active=<0|1>          -> arranca/detiene ese barrido
///   GET /controlip?ip=IP_DE_CONTROL    -> IP de CONTROL para el mando de PS4
///   GET /ping                         -> 200 OK si está vivo
///
/// Mientras el host no esté configurado o no responda, [poll] devuelve
/// `null` y la pantalla Sensores mantiene el generador de datos de
/// demostración (ver `state/app_state.dart`); [sendLed], [setLedSequenceLinked]
/// y [stopLedSequence] devuelven `false` sin lanzar excepción.
class Esp32SensorService {
  final DeviceConfig config;
  Esp32SensorService(this.config);

  String get _host => config.of(HardwareNode.esp32Sensors).host;
  bool get isConfigured => _host.isNotEmpty;

  Future<bool> ping() async {
    if (!isConfigured) return false;
    try {
      final res = await http
          .get(Uri.parse('http://$_host/ping'))
          .timeout(const Duration(seconds: 3));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<SensorPayload?> poll() async {
    if (!isConfigured) return null;
    try {
      final uri = Uri.parse('http://$_host/sensors');
      final res = await http.get(uri).timeout(const Duration(seconds: 3));
      if (res.statusCode != 200) return null;
      return SensorPayload.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  /// Enciende/apaga los faros LED. [index] es 1-4 para un LED puntual
  /// (ver `firmware/SENSORES/SENSORES.ino`); `null` (default) controla los
  /// 4 a la vez.
  Future<bool> sendLed(bool on, {int? index}) async {
    if (!isConfigured) return false;
    try {
      final n = index != null ? '&n=$index' : '';
      final uri = Uri.parse('http://$_host/led?state=${on ? 'on' : 'off'}$n');
      final res = await http.get(uri).timeout(const Duration(seconds: 3));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Excluye (o vuelve a incluir) un LED del barrido "auto increíble" de
  /// arranque — se llama cuando un nodo pasa a estar vinculado ([linked]
  /// true) o deja de estarlo. [number] es 1-4, igual que en [sendLed].
  Future<bool> setLedSequenceLinked(int number, bool linked) async {
    if (!isConfigured) return false;
    try {
      final uri = Uri.parse('http://$_host/ledseq?n=$number&linked=${linked ? 1 : 0}');
      final res = await http.get(uri).timeout(const Duration(seconds: 3));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Le dice a esta placa a qué IP de CONTROL (ESP32-S3) mandar los
  /// comandos del mando de PS4 (/movevec, /armset). El firmware la guarda
  /// en NVS, así que basta con mandarla cuando cambie — ver
  /// `AppState._syncControlIpToSensors`. [controlHost] vacío la borra.
  Future<bool> setControlHost(String controlHost) async {
    if (!isConfigured) return false;
    try {
      final uri = Uri.parse('http://$_host/controlip')
          .replace(queryParameters: {'ip': controlHost});
      final res = await http.get(uri).timeout(const Duration(seconds: 3));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Detiene el barrido "auto increíble" por completo — se llama justo al
  /// presionar "Iniciar", antes de que la app tome control manual de los
  /// LEDs con [sendLed].
  Future<bool> stopLedSequence() async {
    if (!isConfigured) return false;
    try {
      final uri = Uri.parse('http://$_host/ledseq?active=0');
      final res = await http.get(uri).timeout(const Duration(seconds: 3));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }
}
