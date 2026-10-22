import 'dart:math';

import 'package:flutter/material.dart';

import '../app_theme.dart';

/// Anillo de progreso circular, equivalente a `.gauge-ring` (SVG) del
/// prototipo, usado para los sensores MQ.
class GaugeRing extends StatelessWidget {
  final double percent; // 0-100
  final bool warn;
  const GaugeRing({super.key, required this.percent, required this.warn});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 84,
      height: 84,
      child: Stack(
        alignment: Alignment.center,
        children: [
          CustomPaint(
            size: const Size(84, 84),
            painter: _GaugePainter(percent: percent, warn: warn),
          ),
          Text(
            '${percent.round()}%',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: AppColors.text1),
          ),
        ],
      ),
    );
  }
}

class _GaugePainter extends CustomPainter {
  final double percent;
  final bool warn;
  _GaugePainter({required this.percent, required this.warn});

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.width / 2 - 4;
    final bgPaint = Paint()
      ..color = AppColors.surface3
      ..style = PaintingStyle.stroke
      ..strokeWidth = 8;
    canvas.drawCircle(center, radius, bgPaint);

    final fgPaint = Paint()
      ..color = warn ? AppColors.yellow : AppColors.orange
      ..style = PaintingStyle.stroke
      ..strokeWidth = 8
      ..strokeCap = StrokeCap.round;

    final sweep = 2 * pi * (percent.clamp(0, 100) / 100);
    canvas.drawArc(Rect.fromCircle(center: center, radius: radius), -pi / 2, sweep, false, fgPaint);
  }

  @override
  bool shouldRepaint(covariant _GaugePainter oldDelegate) =>
      oldDelegate.percent != percent || oldDelegate.warn != warn;
}
