import 'package:flutter/material.dart';

import '../app_theme.dart';

/// Réplica del fondo SVG "pasillo" del prototipo (`.video-bg` en index.html),
/// usada como imagen de relleno mientras el ESP32-CAM no está vinculado.
class CorridorPlaceholder extends StatelessWidget {
  final int seed;
  const CorridorPlaceholder({super.key, this.seed = 0});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _CorridorPainter(seed: seed),
      child: const SizedBox.expand(),
    );
  }
}

class _CorridorPainter extends CustomPainter {
  final int seed;
  _CorridorPainter({required this.seed});

  @override
  void paint(Canvas canvas, Size size) {
    final bg = seed.isEven ? const Color(0xFF111416) : const Color(0xFF0E1112);
    canvas.drawRect(Offset.zero & size, Paint()..color = bg);

    final line = Paint()
      ..color = const Color(0xFF272B2C)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4;

    final w = size.width, h = size.height;
    final path = Path()
      ..moveTo(0, h * 0.86)
      ..lineTo(w * 0.37, h * 0.5)
      ..lineTo(w * 0.63, h * 0.5)
      ..lineTo(w, h * 0.86);
    canvas.drawPath(path, line);
    canvas.drawLine(Offset(w * 0.37, h * 0.5), Offset(w * 0.37, 0), line);
    canvas.drawLine(Offset(w * 0.63, h * 0.5), Offset(w * 0.63, 0), line);

    canvas.drawCircle(
      Offset(w * 0.5, h * 0.62),
      3,
      Paint()..color = AppColors.orange.withValues(alpha: 0.7),
    );
  }

  @override
  bool shouldRepaint(covariant _CorridorPainter oldDelegate) => oldDelegate.seed != seed;
}
