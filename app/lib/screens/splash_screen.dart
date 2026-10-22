import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../app_theme.dart';

/// Pantalla de arranque de SHADOW BOT: el logo (SHADOWBOTLOGOFINALAPP, sin
/// fondo — `assets/brand/splash_logo.png`) sale de entre humo negro, el ojo
/// rojo late mientras "inicializan los sistemas" (~7 s en total) y al final el logo se
/// deshace en humo negro que se disipa y deja ver la consola, que ya cargó
/// debajo. Va encima de toda la app (ver `main.dart`); tocar la pantalla la
/// adelanta al desvanecido.
class SmokeSplash extends StatefulWidget {
  final VoidCallback onDone;
  const SmokeSplash({super.key, required this.onDone});

  @override
  State<SmokeSplash> createState() => _SmokeSplashState();
}

class _SmokeSplashState extends State<SmokeSplash> with SingleTickerProviderStateMixin {
  static const _totalMs = 7200;
  late final AnimationController _c;
  late final List<_Puff> _puffs;

  @override
  void initState() {
    super.initState();
    final rnd = math.Random(7);
    _puffs = List.generate(46, (i) => _Puff.random(rnd));
    _c =
        AnimationController(
            vsync: this,
            duration: const Duration(milliseconds: _totalMs),
          )
          ..addStatusListener((s) {
            if (s == AnimationStatus.completed) widget.onDone();
          })
          ..forward();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  /// Salta directo al desvanecido en humo.
  void _skip() {
    const dissolveAt = 4500 / _totalMs;
    if (_c.value < dissolveAt) _c.forward(from: dissolveAt);
  }

  /// 0→1 entre [a] y [b] segundos.
  static double _seg(double t, double a, double b, [Curve curve = Curves.easeInOut]) => curve.transform(((t - a) / (b - a)).clamp(0.0, 1.0));

  @override
  Widget build(BuildContext context) {
    // Va por encima del Navigator: sin Material el texto saldría subrayado.
    return Material(
      type: MaterialType.transparency,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _skip,
        child: AnimatedBuilder(
          animation: _c,
          builder: (context, _) {
            final t = _c.value * _totalMs / 1000; // segundos
            final logoIn = _seg(t, 0.3, 2.1, Curves.easeOutCubic);
            final dissolve = _seg(t, 4.5, 6.2, Curves.easeInCubic);
            final reveal = _seg(t, 6.0, 7.2, Curves.easeOut); // la consola aparece debajo
            final smokeIn = 1 - _seg(t, 0.0, 2.4, Curves.easeOut);
            final pulse = 0.5 + 0.5 * math.sin(t * 5.2);

            return Opacity(
              opacity: 1 - reveal,
              child: ColoredBox(
                color: AppColors.ink,
                child: LayoutBuilder(
                  builder: (context, c) {
                    final logoW = math.min(c.maxWidth * 0.62, c.maxHeight * 0.62 * 1100 / 620);
                    final logoH = logoW * 620 / 1100;
                    final box = Rect.fromCenter(center: Offset(c.maxWidth / 2, c.maxHeight * 0.46), width: logoW, height: logoH);
                    final blur = (1 - logoIn) * 9 + dissolve * 16;
                    return Stack(
                      children: [
                        // Halo rojo tenue detrás del logo.
                        Positioned.fill(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: RadialGradient(
                                center: Alignment(0, (box.center.dy / c.maxHeight) * 2 - 1),
                                radius: 0.75,
                                colors: [Color.fromRGBO(120, 10, 12, 0.16 * logoIn * (1 - dissolve)), const Color(0x00000000)],
                              ),
                            ),
                          ),
                        ),
                        Positioned.fromRect(
                          rect: box,
                          child: Opacity(
                            opacity: (logoIn * (1 - dissolve)).clamp(0.0, 1.0),
                            child: Transform.scale(
                              scale: 0.93 + 0.07 * logoIn + 0.1 * dissolve,
                              child: ImageFiltered(
                                imageFilter: ImageFilter.blur(sigmaX: blur + 0.01, sigmaY: blur + 0.01),
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    Image.asset('assets/brand/splash_logo.png', fit: BoxFit.contain, filterQuality: FilterQuality.medium),
                                    // El ojo rojo late.
                                    Align(
                                      alignment: const Alignment(-0.004, -0.316),
                                      child: Container(
                                        width: logoW * 0.12,
                                        height: logoW * 0.12,
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          gradient: RadialGradient(colors: [Color.fromRGBO(255, 40, 30, 0.10 + 0.32 * pulse * logoIn), const Color(0x00FF2010)]),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                        // Humo negro: se abre al principio y se traga el logo al final.
                        Positioned.fill(
                          child: IgnorePointer(
                            child: CustomPaint(
                              painter: _SmokePainter(puffs: _puffs, box: box, t: t, intro: smokeIn, dissolve: dissolve),
                            ),
                          ),
                        ),
                        // Línea de "inicializando sistemas".
                        Positioned(
                          left: 0,
                          right: 0,
                          top: box.bottom + 26,
                          child: Opacity(
                            opacity: (logoIn * (1 - _seg(t, 4.2, 4.9))).clamp(0.0, 1.0),
                            child: Column(
                              children: [
                                SizedBox(
                                  width: math.min(260, logoW * 0.5),
                                  height: 2,
                                  child: LinearProgressIndicator(value: _seg(t, 0.5, 4.2, Curves.easeInOut), backgroundColor: AppColors.line, color: AppColors.olive),
                                ),
                                const SizedBox(height: 10),
                                Text(
                                  t < 1.6 ? 'INICIALIZANDO SISTEMAS' : (t < 2.8 ? 'ENLAZANDO NODOS' : (t < 3.7 ? 'CALIBRANDO CÁMARAS' : 'CONSOLA LISTA')),
                                  style: AppText.label.copyWith(fontSize: 10, letterSpacing: 3, color: AppColors.text2),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Una bocanada de humo: posición relativa al logo, tamaño, deriva y tono.
class _Puff {
  final double x, y; // 0-1 dentro del logo (un poco más allá de los bordes)
  final double r; // radio relativo al ancho del logo
  final double drift; // cuánto sube
  final double sway; // vaivén lateral
  final double phase;
  final double delay; // 0-0.35: no todas arrancan juntas
  final bool wisp; // gris más claro (se ve contra el negro)

  _Puff(this.x, this.y, this.r, this.drift, this.sway, this.phase, this.delay, this.wisp);

  factory _Puff.random(math.Random rnd) => _Puff(
    -0.08 + rnd.nextDouble() * 1.16,
    0.05 + rnd.nextDouble() * 1.0,
    0.07 + rnd.nextDouble() * 0.13,
    0.25 + rnd.nextDouble() * 0.55,
    (rnd.nextDouble() - 0.5) * 0.25,
    rnd.nextDouble() * math.pi * 2,
    rnd.nextDouble() * 0.35,
    rnd.nextDouble() < 0.3,
  );
}

class _SmokePainter extends CustomPainter {
  final List<_Puff> puffs;
  final Rect box;
  final double t; // segundos
  final double intro; // 1 = humo cubriendo, 0 = despejado
  final double dissolve; // 0 = logo entero, 1 = solo humo

  _SmokePainter({required this.puffs, required this.box, required this.t, required this.intro, required this.dissolve});

  @override
  void paint(Canvas canvas, Size size) {
    final w = box.width;
    for (final p in puffs) {
      // Entrada: el humo se abre hacia afuera y se aclara.
      // Salida: cada bocanada nace sobre el logo, crece, sube y se apaga.
      final d = ((dissolve - p.delay) / (1 - p.delay)).clamp(0.0, 1.0);
      final out = d > 0 ? math.sin(math.pi * math.min(1.0, d * 1.15)) : 0.0;
      final a = math.max(intro * 0.9, out * 0.92);
      if (a <= 0.01) continue;
      final opening = intro > 0 ? 1 - intro : 0.0;
      final grow = 1 + d * 1.7 + opening * 0.9;
      final rise = (d * 0.9 + opening * 0.4) * p.drift * box.height;
      final cx = box.left + p.x * w + math.sin(t * 1.3 + p.phase) * p.sway * w;
      final cy = box.top + p.y * box.height - rise;
      final r = p.r * w * grow;
      final core = p.wisp ? const Color(0xFF2A2F38) : const Color(0xFF000000);
      final mid = p.wisp ? const Color(0xFF15181E) : const Color(0xFF07080A);
      final paint = Paint()
        ..shader = RadialGradient(
          colors: [
            core.withValues(alpha: a * (p.wisp ? 0.55 : 0.95)),
            mid.withValues(alpha: a * (p.wisp ? 0.3 : 0.7)),
            mid.withValues(alpha: 0),
          ],
          stops: const [0, 0.55, 1],
        ).createShader(Rect.fromCircle(center: Offset(cx, cy), radius: r));
      canvas.drawCircle(Offset(cx, cy), r, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _SmokePainter old) => old.t != t;
}
