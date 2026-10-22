/// Estado de vinculación de cada nodo de hardware.
///
/// Mientras no se complete la vinculación real, el nodo permanece en
/// [pending] y la app funciona en modo demostración (datos simulados).
enum LinkStatus { pending, connecting, online, error }

/// Identifica los nodos de hardware que la app espera controlar.
/// La vinculación real de cada uno queda pendiente (ver services/).
///
/// [tapoCam] es distinto de los otros tres: no es un nodo propio (firmware
/// del carrito), sino una cámara IP comercial (TP-Link Tapo C110) que se
/// conecta directo por Wi-Fi vía RTSP — no pasa por la ESP32-S3. `host`
/// para este nodo guarda la URL RTSP completa (con usuario/clave), no solo
/// una IP — ver `TapoCamService`.
enum HardwareNode { esp32cam, esp32s3Control, esp32Sensors, tapoCam }

class NodeLink {
  final HardwareNode node;
  final String label;
  final String role;
  LinkStatus status;
  String host; // IP o hostname configurado por el usuario, vacío si no hay.

  /// Latencia REAL del último ping (round-trip a `/ping` o equivalente),
  /// en milisegundos. `null` si nunca se pudo medir (nodo sin vincular o
  /// sin respuesta) — nunca es un valor simulado/inventado, ver
  /// `AppState.pingNode()`.
  int? latencyMs;

  /// Momento del último intento de ping (haya respondido o no).
  DateTime? lastChecked;

  NodeLink({
    required this.node,
    required this.label,
    required this.role,
    this.status = LinkStatus.pending,
    this.host = '',
  });

  bool get isOnline => status == LinkStatus.online;

  String get statusLabel {
    switch (status) {
      case LinkStatus.pending:
        return 'Pendiente de vinculación';
      case LinkStatus.connecting:
        return 'Conectando…';
      case LinkStatus.online:
        return 'En línea';
      case LinkStatus.error:
        return 'Sin respuesta';
    }
  }
}
