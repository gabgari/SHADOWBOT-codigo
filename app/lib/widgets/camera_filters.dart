import 'package:flutter/material.dart';

import 'hud.dart';

/// Filtros visuales que se le pueden aplicar a cualquier feed de cámara
/// (ESP32-CAM o Tapo C110) — son puramente cosméticos, sobre el widget de
/// video ya renderizado, así que funcionan igual sin importar el origen.
enum CameraFilterMode { none, military, blackWhite, nightVision }

extension CameraFilterModeLabel on CameraFilterMode {
  String get label => switch (this) {
        CameraFilterMode.none => 'Normal',
        CameraFilterMode.military => 'Infrarrojo (Militar)',
        CameraFilterMode.blackWhite => 'Blanco y negro',
        CameraFilterMode.nightVision => 'Visión nocturna (verde)',
      };

  String get short => switch (this) {
        CameraFilterMode.none => 'NORMAL',
        CameraFilterMode.military => 'IR',
        CameraFilterMode.blackWhite => 'B/N',
        CameraFilterMode.nightVision => 'VERDE',
      };

  IconData get icon => switch (this) {
        CameraFilterMode.none => Icons.crop_free_rounded,
        CameraFilterMode.military => Icons.track_changes_rounded,
        CameraFilterMode.blackWhite => Icons.contrast_rounded,
        CameraFilterMode.nightVision => Icons.visibility_outlined,
      };
}

/// Envuelve [child] (el widget de video) con el filtro de color + adornos
/// (viñeta, retícula, scanlines) del modo elegido. `none` devuelve [child]
/// tal cual, sin ningún overhead de pintado extra.
class CameraFilterOverlay extends StatelessWidget {
  final CameraFilterMode mode;
  final Widget child;
  const CameraFilterOverlay({super.key, required this.mode, required this.child});

  // Fósforo de intensificador de imagen: monocromo, casi todo el brillo va
  // al canal verde y se le da bastante ganancia — así es como se ve
  // cualquier NVG real.
  static const nightVisionMatrix = <double>[
    0.0448, 0.0880, 0.0171, 0, 0,
    0.4784, 0.9390, 0.1824, 0, 18,
    0.0598, 0.1174, 0.0228, 0, 0,
    0, 0, 0, 1, 0,
  ];

  // Look táctico/monitor militar: desatura hacia un verde oliva apagado,
  // sin el brillo "fósforo" de la visión nocturna — más plano, más gris.
  static const militaryMatrix = <double>[
    0.35, 0.35, 0.35, 0, 6,
    0.48, 0.55, 0.35, 0, 14,
    0.16, 0.16, 0.14, 0, 4,
    0, 0, 0, 1, 0,
  ];

  // Blanco y negro con algo más de contraste (look noir).
  static const bwMatrix = <double>[
    0.30, 0.65, 0.12, 0, -14,
    0.30, 0.65, 0.12, 0, -14,
    0.30, 0.65, 0.12, 0, -14,
    0, 0, 0, 1, 0,
  ];

  /// Matriz de color de [mode] (`null` = sin filtro). La usa también
  /// `services/frame_filter.dart` para "quemar" el mismo filtro en las
  /// fotos y videos que se guardan en Multimedia.
  static List<double>? matrixFor(CameraFilterMode mode) => switch (mode) {
        CameraFilterMode.none => null,
        CameraFilterMode.nightVision => nightVisionMatrix,
        CameraFilterMode.military => militaryMatrix,
        CameraFilterMode.blackWhite => bwMatrix,
      };

  @override
  Widget build(BuildContext context) {
    switch (mode) {
      case CameraFilterMode.none:
        return child;
      case CameraFilterMode.nightVision:
        return Stack(
          fit: StackFit.expand,
          children: [
            ColorFiltered(colorFilter: const ColorFilter.matrix(nightVisionMatrix), child: child),
            const IgnorePointer(child: _Vignette(color: Color(0xFF001A05))),
            IgnorePointer(child: CustomPaint(painter: _ScanlinePainter(color: Colors.black.withValues(alpha: 0.10), spacing: 3))),
          ],
        );
      case CameraFilterMode.blackWhite:
        return Stack(
          fit: StackFit.expand,
          children: [
            ColorFiltered(colorFilter: const ColorFilter.matrix(bwMatrix), child: child),
            const IgnorePointer(child: _Vignette(color: Colors.black)),
          ],
        );
      case CameraFilterMode.military:
        return Stack(
          fit: StackFit.expand,
          children: [
            ColorFiltered(colorFilter: const ColorFilter.matrix(militaryMatrix), child: child),
            const IgnorePointer(child: _Vignette(color: Colors.black)),
            IgnorePointer(child: CustomPaint(painter: _ScanlinePainter(color: Colors.black.withValues(alpha: 0.14), spacing: 4))),
            const IgnorePointer(child: _HudCorners()),
          ],
        );
    }
  }
}

/// Fila de botones para elegir el filtro — reutilizable bajo cualquier
/// cámara.
class CameraFilterSelector extends StatelessWidget {
  final CameraFilterMode value;
  final ValueChanged<CameraFilterMode> onChanged;
  const CameraFilterSelector({super.key, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: CameraFilterMode.values
          .map((mode) => HudChip(text: mode.short, icon: mode.icon, active: mode == value, onTap: () => onChanged(mode)))
          .toList(),
    );
  }
}

class _Vignette extends StatelessWidget {
  final Color color;
  const _Vignette({required this.color});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: RadialGradient(
          center: Alignment.center,
          radius: 0.95,
          colors: [Colors.transparent, color.withValues(alpha: 0.55)],
          stops: const [0.55, 1.0],
        ),
      ),
    );
  }
}

class _ScanlinePainter extends CustomPainter {
  final Color color;
  final double spacing;
  const _ScanlinePainter({required this.color, required this.spacing});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    for (double y = 0; y < size.height; y += spacing) {
      canvas.drawRect(Rect.fromLTWH(0, y, size.width, spacing / 2), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _ScanlinePainter oldDelegate) => oldDelegate.color != color || oldDelegate.spacing != spacing;
}

class _HudCorners extends StatelessWidget {
  const _HudCorners();

  @override
  Widget build(BuildContext context) {
    const c = Color(0x9993A1C6);
    const len = 16.0;
    const thick = 2.0;
    Widget corner() => const SizedBox(
          width: len,
          height: len,
          child: CustomPaint(painter: _CornerPainter(color: c, thickness: thick)),
        );
    return Padding(
      padding: const EdgeInsets.all(10),
      child: Stack(
        children: [
          Align(alignment: Alignment.topLeft, child: corner()),
          Align(alignment: Alignment.topRight, child: Transform.rotate(angle: 1.5708, child: corner())),
          Align(alignment: Alignment.bottomLeft, child: Transform.rotate(angle: -1.5708, child: corner())),
          Align(alignment: Alignment.bottomRight, child: Transform.rotate(angle: 3.14159, child: corner())),
        ],
      ),
    );
  }
}

class _CornerPainter extends CustomPainter {
  final Color color;
  final double thickness;
  const _CornerPainter({required this.color, required this.thickness});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = thickness
      ..style = PaintingStyle.stroke;
    final path = Path()
      ..moveTo(0, size.height)
      ..lineTo(0, 0)
      ..lineTo(size.width, 0);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

