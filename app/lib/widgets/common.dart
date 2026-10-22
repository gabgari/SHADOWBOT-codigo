import 'package:flutter/material.dart';

import '../app_theme.dart';

/// Título de sección estilo HUD: mono, mayúsculas, con una línea tenue que
/// corre hasta el borde.
class SectionTitle extends StatelessWidget {
  final String text;
  final EdgeInsets padding;
  const SectionTitle(this.text, {super.key, this.padding = const EdgeInsets.fromLTRB(2, 20, 2, 10)});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Row(
        children: [
          Text(text.toUpperCase(), style: AppText.sectionTitle),
          const SizedBox(width: 10),
          const Expanded(child: Divider(color: AppColors.lineSoft, height: 1)),
        ],
      ),
    );
  }
}

/// Panel de la consola: grafito profundo, borde de 1px gris carbón,
/// esquinas cortas. Es la "tarjeta" de toda la app.
class AppCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  const AppCard({super.key, required this.child, this.padding = const EdgeInsets.all(14)});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: AppColors.surface1.withValues(alpha: 0.92),
        border: Border.all(color: AppColors.line),
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: child,
    );
  }
}

/// Botón principal: fondo verde militar oscuro, borde verde militar, texto
/// mono espaciado y flecha — como "INICIAR >" de la guía de estilo.
class PrimaryButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  const PrimaryButton({super.key, required this.label, this.onPressed, this.icon});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(label.toUpperCase(), style: const TextStyle(fontFamily: AppFonts.mono, fontWeight: FontWeight.w500, fontSize: 13, letterSpacing: 1.6)),
            if (icon != null) ...[const SizedBox(width: 10), Icon(icon, size: 16)],
          ],
        ),
      ),
    );
  }
}

class GhostButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  const GhostButton({super.key, required this.label, this.onPressed});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          backgroundColor: AppColors.surface1,
          padding: const EdgeInsets.symmetric(vertical: 13),
        ),
        child: Text(label.toUpperCase(), style: const TextStyle(fontFamily: AppFonts.mono, fontWeight: FontWeight.w500, fontSize: 12, letterSpacing: 1.4)),
      ),
    );
  }
}

/// Aviso flotante breve.
void showAppToast(BuildContext context, String message) {
  final overlay = Overlay.of(context);
  late OverlayEntry entry;
  entry = OverlayEntry(
    builder: (ctx) => Positioned(
      left: 24,
      right: 24,
      bottom: 64,
      child: Center(
        child: Material(
          color: Colors.transparent,
          child: Container(
            constraints: const BoxConstraints(maxWidth: 560),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: AppColors.ink.withValues(alpha: 0.95),
              borderRadius: BorderRadius.circular(AppRadius.md),
              border: Border.all(color: AppColors.military),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(width: 6, height: 6, decoration: const BoxDecoration(color: AppColors.olive, shape: BoxShape.circle)),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(
                    message,
                    style: const TextStyle(color: AppColors.text1, fontSize: 12, fontFamily: AppFonts.mono),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  overlay.insert(entry);
  Future.delayed(const Duration(milliseconds: 2200), () => entry.remove());
}
