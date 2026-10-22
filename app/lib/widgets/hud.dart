import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../app_theme.dart';

// =============================================================
//  Piezas de la consola SHADOW BOT (estilo software de ROV / militar):
//  paneles, indicadores, joysticks, brújula, marcos de cámara.
//  Todo mide en función de `context.u` para verse igual de proporcionado
//  en un teléfono acostado y en una tablet.
// =============================================================

/// Panel con título HUD (ícono + texto mono) y contenido.
class HudPanel extends StatelessWidget {
  final String? title;
  final IconData? icon;
  final Widget? trailing;
  final Widget child;
  final EdgeInsetsGeometry? padding;

  const HudPanel({super.key, this.title, this.icon, this.trailing, required this.child, this.padding});

  @override
  Widget build(BuildContext context) {
    final u = context.u;
    return Container(
      width: double.infinity,
      padding: padding ?? EdgeInsets.fromLTRB(12 * u, 10 * u, 12 * u, 12 * u),
      decoration: BoxDecoration(
        color: AppColors.surface1.withValues(alpha: 0.88),
        border: Border.all(color: AppColors.line),
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (title != null) ...[
            Row(
              children: [
                if (icon != null) ...[Icon(icon, size: 14 * u, color: AppColors.text2), SizedBox(width: 8 * u)],
                Expanded(child: Text(title!.toUpperCase(), style: AppText.sectionTitle, overflow: TextOverflow.ellipsis)),
                ?trailing,
              ],
            ),
            SizedBox(height: 10 * u),
          ],
          child,
        ],
      ),
    );
  }
}

/// Punto de estado (verde oliva = activo) con un halo tenue.
class StatusDot extends StatelessWidget {
  final Color color;
  final double size;
  const StatusDot({super.key, this.color = AppColors.olive, this.size = 7});

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          boxShadow: [BoxShadow(color: color.withValues(alpha: 0.55), blurRadius: size)],
        ),
      );
}

/// Chip HUD: borde fino, fondo tinta translúcido, texto mono.
class HudChip extends StatelessWidget {
  final String text;
  final IconData? icon;
  final Color? dot;
  final VoidCallback? onTap;
  final bool active;
  const HudChip({super.key, required this.text, this.icon, this.dot, this.onTap, this.active = false});

  @override
  Widget build(BuildContext context) {
    final u = context.u;
    return Material(
      color: active ? AppColors.militaryDark.withValues(alpha: 0.85) : AppColors.ink.withValues(alpha: 0.72),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        side: BorderSide(color: active ? AppColors.military : AppColors.line),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 10 * u, vertical: 6 * u),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[Icon(icon, size: 13 * u, color: active ? AppColors.text1 : AppColors.text2), SizedBox(width: 7 * u)],
              Text(text.toUpperCase(), style: AppText.label.copyWith(color: AppColors.text1, fontSize: 10)),
              if (dot != null) ...[SizedBox(width: 8 * u), StatusDot(color: dot!, size: 6)],
            ],
          ),
        ),
      ),
    );
  }
}

/// Botón cuadrado de ícono (capturar, pantalla completa, flechas…).
class HudIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double size;
  final bool active;
  final bool danger;
  final String? tooltip;
  final bool round;

  const HudIconButton({
    super.key,
    required this.icon,
    this.onTap,
    this.onLongPress,
    this.size = 38,
    this.active = false,
    this.danger = false,
    this.tooltip,
    this.round = false,
  });

  @override
  Widget build(BuildContext context) {
    final u = context.u;
    final s = size * u;
    final border = danger ? AppColors.red : (active ? AppColors.military : AppColors.line);
    final fg = danger ? AppColors.red : (active ? AppColors.text1 : AppColors.text2);
    final bg = danger
        ? AppColors.red.withValues(alpha: 0.10)
        : (active ? AppColors.militaryDark.withValues(alpha: 0.8) : AppColors.ink.withValues(alpha: 0.6));
    final shape = round
        ? CircleBorder(side: BorderSide(color: border))
        : RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.md), side: BorderSide(color: border));
    final btn = Material(
      color: bg,
      shape: shape,
      child: InkWell(
        customBorder: shape,
        onTap: onTap,
        onLongPress: onLongPress,
        child: SizedBox(width: s, height: s, child: Icon(icon, size: s * 0.46, color: onTap == null ? AppColors.text3 : fg)),
      ),
    );
    return tooltip == null ? btn : Tooltip(message: tooltip!, child: btn);
  }
}

/// Barra horizontal de nivel (0..1), con relleno gris claro y punta oliva.
class BarMeter extends StatelessWidget {
  final double value;
  final Color color;
  final double height;
  const BarMeter({super.key, required this.value, this.color = AppColors.text2, this.height = 6});

  @override
  Widget build(BuildContext context) {
    final v = value.clamp(0.0, 1.0);
    return ClipRRect(
      borderRadius: BorderRadius.circular(2),
      child: SizedBox(
        height: height,
        child: Stack(
          children: [
            Container(color: AppColors.surface3.withValues(alpha: 0.6)),
            FractionallySizedBox(
              widthFactor: v,
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(colors: [color.withValues(alpha: 0.55), color]),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Línea de tendencia mínima (ping, gas…).
class Sparkline extends StatelessWidget {
  final List<double> values;
  final Color color;
  final double height;
  const Sparkline({super.key, required this.values, this.color = AppColors.text2, this.height = 22});

  @override
  Widget build(BuildContext context) =>
      SizedBox(height: height * context.u, child: CustomPaint(painter: _SparkPainter(values, color), size: Size.infinite));
}

class _SparkPainter extends CustomPainter {
  final List<double> v;
  final Color color;
  _SparkPainter(this.v, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    if (v.length < 2) {
      final p = Paint()..color = AppColors.surface3..strokeWidth = 1;
      canvas.drawLine(Offset(0, size.height / 2), Offset(size.width, size.height / 2), p);
      return;
    }
    final lo = v.reduce(min), hi = v.reduce(max);
    final span = (hi - lo).abs() < 1e-6 ? 1.0 : hi - lo;
    final path = Path();
    for (var i = 0; i < v.length; i++) {
      final x = size.width * i / (v.length - 1);
      final y = size.height - 2 - (size.height - 4) * (v[i] - lo) / span;
      i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
    );
    final last = Offset(size.width, size.height - 2 - (size.height - 4) * (v.last - lo) / span);
    canvas.drawCircle(last, 2, Paint()..color = AppColors.olive);
  }

  @override
  bool shouldRepaint(covariant _SparkPainter old) => true;
}

/// Barras de señal según RSSI (dBm).
class SignalBars extends StatelessWidget {
  final int? rssi;
  const SignalBars({super.key, this.rssi});

  @override
  Widget build(BuildContext context) {
    final u = context.u;
    final r = rssi;
    final lit = r == null ? 0 : ((r + 95) / 6).clamp(0, 8).round();
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: List.generate(8, (i) {
        return Container(
          width: 3 * u,
          height: (4 + i * 2.2) * u,
          margin: EdgeInsets.only(left: 2 * u),
          color: i < lit ? (i >= 6 ? AppColors.olive : AppColors.text2) : AppColors.surface3,
        );
      }),
    );
  }
}

/// Reloj HH:MM:SS que se actualiza solo.
class HudClock extends StatefulWidget {
  final TextStyle? style;
  const HudClock({super.key, this.style});

  @override
  State<HudClock> createState() => _HudClockState();
}

class _HudClockState extends State<HudClock> {
  late Timer _t;
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(seconds: 1), (_) => setState(() => _now = DateTime.now()));
  }

  @override
  void dispose() {
    _t.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    String two(int n) => n.toString().padLeft(2, '0');
    return Text('${two(_now.hour)}:${two(_now.minute)}:${two(_now.second)}', style: widget.style ?? AppText.value.copyWith(fontSize: 13));
  }
}

// ---------------- Marcos de cámara ----------------

/// Esquinas tipo visor + mira central.
class ViewfinderOverlay extends StatelessWidget {
  final bool crosshair;
  const ViewfinderOverlay({super.key, this.crosshair = true});

  @override
  Widget build(BuildContext context) =>
      IgnorePointer(child: CustomPaint(painter: _ViewfinderPainter(crosshair, context.u), size: Size.infinite));
}

class _ViewfinderPainter extends CustomPainter {
  final bool crosshair;
  final double u;
  _ViewfinderPainter(this.crosshair, this.u);

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = AppColors.text1.withValues(alpha: 0.75)
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;
    final m = 14.0 * u, l = min(26.0 * u, size.shortestSide * 0.12);
    final w = size.width, h = size.height;
    void corner(Offset o, double dx, double dy) {
      canvas.drawPath(Path()
        ..moveTo(o.dx, o.dy + dy * l)
        ..lineTo(o.dx, o.dy)
        ..lineTo(o.dx + dx * l, o.dy), p);
    }

    corner(Offset(m, m), 1, 1);
    corner(Offset(w - m, m), -1, 1);
    corner(Offset(m, h - m), 1, -1);
    corner(Offset(w - m, h - m), -1, -1);

    if (crosshair) {
      final c = size.center(Offset.zero);
      final cp = Paint()
        ..color = AppColors.text1.withValues(alpha: 0.6)
        ..strokeWidth = 1;
      final a = 14.0 * u, g = 4.0 * u;
      canvas.drawLine(c.translate(-a, 0), c.translate(-g, 0), cp);
      canvas.drawLine(c.translate(g, 0), c.translate(a, 0), cp);
      canvas.drawLine(c.translate(0, -a), c.translate(0, -g), cp);
      canvas.drawLine(c.translate(0, g), c.translate(0, a), cp);
    }
  }

  @override
  bool shouldRepaint(covariant _ViewfinderPainter old) => old.crosshair != crosshair || old.u != u;
}

/// Brújula circular (rumbo en grados).
class HudCompass extends StatelessWidget {
  final double heading;
  final double size;
  final String caption;
  const HudCompass({super.key, required this.heading, this.size = 110, this.caption = 'RUMBO'});

  @override
  Widget build(BuildContext context) {
    final s = size * context.u;
    final h = ((heading % 360) + 360) % 360;
    return SizedBox(
      width: s,
      height: s,
      child: Stack(
        alignment: Alignment.center,
        children: [
          CustomPaint(painter: _CompassPainter(h), size: Size(s, s)),
          Positioned(
            bottom: s * 0.25,
            child: Column(
              children: [
                Text('${h.round()}°', style: AppText.value.copyWith(fontSize: s * 0.11)),
                Text(caption, style: AppText.label.copyWith(fontSize: s * 0.06)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CompassPainter extends CustomPainter {
  final double heading;
  _CompassPainter(this.heading);

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2 - 8;
    final ring = Paint()
      ..color = AppColors.text1.withValues(alpha: 0.55)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawCircle(c, r, ring);
    canvas.drawCircle(c, r * 0.72, ring..color = AppColors.text1.withValues(alpha: 0.18));
    // Marcas cada 10°, giradas al revés del rumbo (la rosa gira, la flecha no).
    for (var d = 0; d < 360; d += 10) {
      final a = (d - heading - 90) * pi / 180;
      final len = d % 90 == 0 ? 8.0 : (d % 30 == 0 ? 5.0 : 3.0);
      final p1 = c + Offset(cos(a), sin(a)) * r;
      final p2 = c + Offset(cos(a), sin(a)) * (r - len);
      canvas.drawLine(p1, p2, Paint()..color = AppColors.text1.withValues(alpha: d % 90 == 0 ? 0.9 : 0.45)..strokeWidth = 1);
    }
    const names = {0: 'N', 90: 'E', 180: 'S', 270: 'W'};
    names.forEach((d, n) {
      final a = (d - heading - 90) * pi / 180;
      final pos = c + Offset(cos(a), sin(a)) * (r + 0.5 - 16);
      final tp = TextPainter(
        text: TextSpan(text: n, style: TextStyle(fontFamily: AppFonts.mono, fontSize: size.width * 0.075, color: AppColors.text1)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, pos - Offset(tp.width / 2, tp.height / 2));
    });
    // Flecha fija hacia arriba.
    final arrow = Path()
      ..moveTo(c.dx, c.dy - r * 0.52)
      ..lineTo(c.dx + r * 0.14, c.dy - r * 0.12)
      ..lineTo(c.dx, c.dy - r * 0.2)
      ..lineTo(c.dx - r * 0.14, c.dy - r * 0.12)
      ..close();
    canvas.drawPath(arrow, Paint()..color = AppColors.text1);
  }

  @override
  bool shouldRepaint(covariant _CompassPainter old) => old.heading != heading;
}

// ---------------- Joysticks ----------------

/// Joystick de MANEJO (8 direcciones). Mientras el dedo está abajo avisa la
/// dirección (`onDrive`), y al soltar llama `onRelease` — quien lo usa
/// decide cómo repetir el comando (ver `AppState.holdMove`).
class DriveJoystick extends StatefulWidget {
  final double size;
  final void Function(String move) onDrive;
  final VoidCallback onRelease;
  final String active; // movimiento que se está mandando ahora (para resaltar)
  const DriveJoystick({super.key, this.size = 130, required this.onDrive, required this.onRelease, this.active = ''});

  @override
  State<DriveJoystick> createState() => _DriveJoystickState();
}

class _DriveJoystickState extends State<DriveJoystick> {
  Offset _knob = Offset.zero; // -1..1
  String? _move;

  static const _sectors = ['derecha', 'diag-der', 'adelante', 'diag-izq', 'izquierda', 'atras', 'atras', 'atras'];

  String? _moveFor(Offset v) {
    if (v.distance < 0.28) return null;
    // Ángulo con 0° a la derecha y creciendo hacia arriba.
    var a = atan2(-v.dy, v.dx) * 180 / pi;
    if (a < 0) a += 360;
    final i = ((a + 22.5) % 360 ~/ 45);
    return _sectors[i];
  }

  void _update(Offset local, double s) {
    final c = Offset(s / 2, s / 2);
    var v = (local - c) / (s / 2);
    if (v.distance > 1) v = v / v.distance;
    final m = _moveFor(v);
    setState(() => _knob = v);
    if (m != _move) {
      _move = m;
      if (m == null) {
        widget.onRelease();
      } else {
        widget.onDrive(m);
      }
    }
  }

  void _end() {
    setState(() => _knob = Offset.zero);
    if (_move != null) widget.onRelease();
    _move = null;
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.size * context.u;
    return GestureDetector(
      onPanStart: (d) => _update(d.localPosition, s),
      onPanUpdate: (d) => _update(d.localPosition, s),
      onPanEnd: (_) => _end(),
      onPanCancel: _end,
      child: SizedBox(
        width: s,
        height: s,
        child: CustomPaint(painter: _PadPainter(knob: _knob, highlight: widget.active)),
      ),
    );
  }
}

/// Joystick del BRAZO: la perilla ES la posición del brazo (pan = X,
/// tilt = Y, 0-100%). Arrastrar mueve los servos en vivo.
class ArmJoystick extends StatelessWidget {
  final double size;
  final int pan;
  final int tilt;
  final void Function(int pan, int tilt) onChanged;
  const ArmJoystick({super.key, this.size = 110, required this.pan, required this.tilt, required this.onChanged});

  void _set(Offset local, double s) {
    final x = (local.dx / s).clamp(0.0, 1.0);
    final y = (local.dy / s).clamp(0.0, 1.0);
    onChanged((x * 100).round(), ((1 - y) * 100).round());
  }

  @override
  Widget build(BuildContext context) {
    final s = size * context.u;
    final knob = Offset(pan / 50 - 1, 1 - tilt / 50);
    return GestureDetector(
      onPanStart: (d) => _set(d.localPosition, s),
      onPanUpdate: (d) => _set(d.localPosition, s),
      onTapDown: (d) => _set(d.localPosition, s),
      child: SizedBox(width: s, height: s, child: CustomPaint(painter: _PadPainter(knob: knob, arm: true))),
    );
  }
}

class _PadPainter extends CustomPainter {
  final Offset knob;
  final String highlight;
  final bool arm;
  _PadPainter({required this.knob, this.highlight = '', this.arm = false});

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2 - 1;
    canvas.drawCircle(c, r, Paint()..color = AppColors.ink.withValues(alpha: 0.55));
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..color = AppColors.text2.withValues(alpha: 0.55)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
    canvas.drawCircle(
      c,
      r * 0.62,
      Paint()
        ..color = AppColors.line
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
    if (arm) {
      // Retícula de posición.
      final g = Paint()
        ..color = AppColors.line
        ..strokeWidth = 1;
      canvas.drawLine(Offset(c.dx - r, c.dy), Offset(c.dx + r, c.dy), g);
      canvas.drawLine(Offset(c.dx, c.dy - r), Offset(c.dx, c.dy + r), g);
    }
    // Flechas en los 4 lados.
    void chevron(double ang, bool lit) {
      final p = Paint()
        ..color = lit ? AppColors.olive : AppColors.text1.withValues(alpha: 0.7)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..strokeCap = StrokeCap.round;
      final dir = Offset(cos(ang), sin(ang));
      final perp = Offset(-dir.dy, dir.dx);
      final tip = c + dir * (r * 0.84);
      final base = c + dir * (r * 0.74);
      canvas.drawLine(base + perp * (r * 0.08), tip, p);
      canvas.drawLine(base - perp * (r * 0.08), tip, p);
    }

    chevron(-pi / 2, highlight == 'adelante');
    chevron(pi / 2, highlight == 'atras');
    chevron(pi, highlight == 'izquierda');
    chevron(0, highlight == 'derecha');

    // Perilla.
    final k = c + Offset(knob.dx, knob.dy) * (r * (arm ? 0.78 : 0.5));
    final kr = r * (arm ? 0.2 : 0.3);
    canvas.drawCircle(
      k,
      kr,
      Paint()
        ..shader = RadialGradient(colors: [AppColors.surface3, AppColors.surface1]).createShader(Rect.fromCircle(center: k, radius: kr)),
    );
    canvas.drawCircle(
      k,
      kr,
      Paint()
        ..color = highlight.isNotEmpty || arm ? AppColors.military : AppColors.text3
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
    if (!arm) {
      canvas.drawLine(k.translate(0, -kr * 0.35), k.translate(0, kr * 0.35), Paint()..color = AppColors.text3..strokeWidth = 1);
    }
  }

  @override
  bool shouldRepaint(covariant _PadPainter old) => old.knob != knob || old.highlight != highlight;
}

/// Logo circular de SHADOW BOT.
class ShadowLogo extends StatelessWidget {
  final double size;
  const ShadowLogo({super.key, this.size = 28});

  @override
  Widget build(BuildContext context) => Image.asset('assets/brand/logo.png', width: size, height: size, filterQuality: FilterQuality.medium);
}
