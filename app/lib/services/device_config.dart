import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/node_link.dart';

/// Guarda y expone la configuración de red de los tres nodos de hardware.
///
/// *** VINCULACIÓN PENDIENTE (parcial) ***
/// Esta clase solo persiste el host/IP que el usuario escriba en
/// Sistema > Conexiones. La app arranca siempre con los tres nodos en
/// [LinkStatus.pending]: el enlace real (probar conexión, mantenerla,
/// reconectar) se implementa en los `*_service.dart` de esta misma carpeta.
/// El firmware de los tres nodos ya existe en `firmware/` (carpeta raíz del
/// repo): `firmware/CAMARA/CAMARA.ino`, `firmware/CONTROL/CONTROL.ino` y
/// `firmware/SENSORES/SENSORES.ino`. Falta flashearlos y cargar aquí las
/// IPs reales desde Sistema > Conexiones.
class DeviceConfig extends ChangeNotifier {
  static const _keyCam = 'host_esp32cam';
  static const _keyControl = 'host_esp32s3_control';
  static const _keySensors = 'host_esp32_sensors';
  static const _keyTapo = 'host_tapo_cam';

  final Map<HardwareNode, NodeLink> nodes = {
    HardwareNode.esp32cam: NodeLink(
      node: HardwareNode.esp32cam,
      label: 'ESP32-CAM',
      role: 'Video',
    ),
    HardwareNode.esp32s3Control: NodeLink(
      node: HardwareNode.esp32s3Control,
      label: 'ESP32-S3',
      role: 'Coordinador / Control de motores',
    ),
    HardwareNode.esp32Sensors: NodeLink(
      node: HardwareNode.esp32Sensors,
      label: 'ESP32',
      role: 'Sensores (MQ-2) + LEDs',
    ),
    HardwareNode.tapoCam: NodeLink(
      node: HardwareNode.tapoCam,
      label: 'Tapo C110',
      role: 'Cámara IP RTSP (visión nocturna)',
    ),
  };

  bool _loaded = false;
  bool get loaded => _loaded;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    nodes[HardwareNode.esp32cam]!.host = prefs.getString(_keyCam) ?? '';
    nodes[HardwareNode.esp32s3Control]!.host = prefs.getString(_keyControl) ?? '';
    nodes[HardwareNode.esp32Sensors]!.host = prefs.getString(_keySensors) ?? '';
    nodes[HardwareNode.tapoCam]!.host = prefs.getString(_keyTapo) ?? '';
    _loaded = true;
    notifyListeners();
  }

  NodeLink of(HardwareNode node) => nodes[node]!;

  Future<void> setHost(HardwareNode node, String host) async {
    nodes[node]!.host = host.trim();
    nodes[node]!.status = LinkStatus.pending;
    final prefs = await SharedPreferences.getInstance();
    switch (node) {
      case HardwareNode.esp32cam:
        await prefs.setString(_keyCam, nodes[node]!.host);
        break;
      case HardwareNode.esp32s3Control:
        await prefs.setString(_keyControl, nodes[node]!.host);
        break;
      case HardwareNode.esp32Sensors:
        await prefs.setString(_keySensors, nodes[node]!.host);
        break;
      case HardwareNode.tapoCam:
        await prefs.setString(_keyTapo, nodes[node]!.host);
        break;
    }
    notifyListeners();
  }

  void setStatus(HardwareNode node, LinkStatus status) {
    nodes[node]!.status = status;
    notifyListeners();
  }

  /// Registra el resultado de un ping real (ver `AppState.pingNode`):
  /// estado + latencia medida con un `Stopwatch` alrededor de la petición
  /// HTTP real al nodo. `latencyMs` debe venir de esa medición o ser
  /// `null` — nunca un valor simulado.
  void reportPing(HardwareNode node, {required bool ok, int? latencyMs}) {
    final link = nodes[node]!;
    link.status = ok ? LinkStatus.online : LinkStatus.error;
    link.latencyMs = ok ? latencyMs : null;
    link.lastChecked = DateTime.now();
    notifyListeners();
  }

  // La Tapo queda afuera a propósito: es un accesorio de cámara
  // independiente (ni pasa por la ESP32-S3 ni es indispensable para que el
  // carrito funcione), así que no vinculada no debería tapar el aviso de
  // "todo listo" del robot ni hacer sonar la alarma de "vinculación
  // pendiente" en NodosScreen — esos dos resumen solo el hardware propio.
  Iterable<NodeLink> get _coreNodes => nodes.entries.where((e) => e.key != HardwareNode.tapoCam).map((e) => e.value);
  bool get anyOnline => _coreNodes.any((n) => n.isOnline);
  bool get allOnline => _coreNodes.every((n) => n.isOnline);
}
