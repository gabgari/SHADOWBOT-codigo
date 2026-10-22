import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_theme.dart';
import '../services/frame_filter.dart' show jpegSize;
import '../services/vision_service.dart';
import '../state/app_state.dart';
import 'common.dart';

/// Video de la PC de VISIÓN IA (MJPEG con los recuadros de YOLO). Mientras
/// está en pantalla mantiene abierta la conexión compartida de
/// [VisionService] y la suelta al salir. Encima pinta el banner rojo
/// "FUEGO DETECTADO" cuando la IA ve fuego.
class VisionView extends StatefulWidget {
  final BoxFit fit;
  const VisionView({super.key, this.fit = BoxFit.cover});

  @override
  State<VisionView> createState() => _VisionViewState();
}

class _VisionViewState extends State<VisionView> {
  late final VisionService _vision;
  /// Lee el tamaño del encabezado del JPEG (no lo decodifica: es barato).
  bool _isPortrait(Uint8List jpeg) {
    final size = jpegSize(jpeg);
    return size != null && size.$2 > size.$1;
  }

  @override
  void initState() {
    super.initState();
    _vision = context.read<AppState>().vision;
    _vision.acquire();
  }

  @override
  void dispose() {
    _vision.release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        ValueListenableBuilder<Uint8List?>(
          valueListenable: _vision.frame,
          builder: (context, jpeg, _) => jpeg == null
              ? const ColoredBox(
                  color: AppColors.ink,
                  child: Center(
                    child: Text('Conectando con la PC de visión…', style: TextStyle(color: AppColors.text2, fontSize: 12, fontWeight: FontWeight.w600)),
                  ),
                )
              // Si la PC endereza una cámara montada de lado, el cuadro llega
              // vertical: se muestra completo (con bandas) en vez de recortarlo.
              : Image.memory(jpeg, fit: _isPortrait(jpeg) ? BoxFit.contain : widget.fit, gaplessPlayback: true, filterQuality: FilterQuality.medium),
        ),
        const Positioned(left: 0, right: 0, top: 0, child: Center(child: FireBanner())),
        // Resumen de lo que ve (solo si el recuadro no es una miniatura).
        LayoutBuilder(
          builder: (context, c) => c.maxWidth < 260
              ? const SizedBox.shrink()
              : Align(
                  alignment: Alignment.bottomCenter,
                  child: Padding(padding: EdgeInsets.only(bottom: 56 * context.u), child: const VisionSummary()),
                ),
        ),
      ],
    );
  }
}

/// Resumen de `conteo`: "👤 2 · 🚗 1 · 🧱 Fisuras 1" (solo lo que hay).
/// Los recuadros ya vienen dibujados en el video; esto es solo el total.
class VisionSummary extends StatelessWidget {
  const VisionSummary({super.key});

  @override
  Widget build(BuildContext context) {
    final vision = context.watch<AppState>().vision;
    return ListenableBuilder(
      listenable: vision,
      builder: (context, _) {
        final items = [
          for (final c in VisionCategory.all)
            if ((vision.conteo[c] ?? 0) > 0) _countText(c, vision.conteo[c]!),
          // Categorías nuevas que la app aún no conoce.
          for (final e in vision.conteo.entries)
            if (!VisionCategory.all.contains(e.key)) '${e.key} ${e.value}',
        ];
        if (!vision.iaActive || items.isEmpty) return const SizedBox.shrink();
        final u = context.u;
        return Container(
          padding: EdgeInsets.symmetric(horizontal: 10 * u, vertical: 4 * u),
          decoration: BoxDecoration(
            color: AppColors.ink.withValues(alpha: 0.78),
            border: Border.all(color: AppColors.line),
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
          child: Text(items.join('  ·  '), style: AppText.label.copyWith(fontSize: 10.5, color: AppColors.text1, letterSpacing: 0.6)),
        );
      },
    );
  }

  static String _countText(String c, int n) {
    final label = VisionCategory.label(c);
    return label.isEmpty ? '${VisionCategory.emoji(c)} $n' : '${VisionCategory.emoji(c)} $label $n';
  }
}

/// Modos de la PC de visión: 🔥 Fuego · 🛡 Seguridad · 🔧 Inspección · ✨ Todo,
/// con la velocidad aproximada debajo. [compact] = un solo chip con menú
/// (para encima del video).
class VisionModeSelector extends StatelessWidget {
  final bool compact;
  const VisionModeSelector({super.key, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final vision = context.watch<AppState>().vision;
    return ListenableBuilder(
      listenable: vision,
      builder: (context, _) {
        if (!vision.iaActive) return const SizedBox.shrink();
        final u = context.u;
        final current = vision.modoPending ?? vision.modo;
        Future<void> pick(String m) async {
          if (m == vision.modo) return;
          final err = await vision.setModo(m);
          if (context.mounted) showAppToast(context, err ?? 'Visión IA: modo ${VisionMode.label(m).toUpperCase()} (${VisionMode.speed(m)})');
        }

        if (compact) {
          return PopupMenuButton<String>(
            tooltip: 'Modo de la IA',
            color: AppColors.surface1,
            onSelected: pick,
            itemBuilder: (_) => [
              for (final m in vision.modos)
                PopupMenuItem(
                  value: m,
                  child: Text('${VisionMode.emoji(m)}  ${VisionMode.label(m)}  ·  ${VisionMode.speed(m)}',
                      style: TextStyle(fontSize: 12, color: m == vision.modo ? AppColors.olive : AppColors.text1, fontWeight: m == vision.modo ? FontWeight.w700 : FontWeight.w500)),
                ),
            ],
            child: Container(
              padding: EdgeInsets.symmetric(horizontal: 7 * u, vertical: 3 * u),
              decoration: BoxDecoration(
                color: AppColors.ink.withValues(alpha: 0.7),
                border: Border.all(color: AppColors.military),
                borderRadius: BorderRadius.circular(AppRadius.sm),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(current == null ? 'MODO' : '${VisionMode.emoji(current)} ${VisionMode.label(current).toUpperCase()}',
                      style: AppText.label.copyWith(fontSize: 8.5, color: AppColors.text1)),
                  Icon(Icons.arrow_drop_down_rounded, size: 14 * u, color: AppColors.text2),
                ],
              ),
            ),
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 6 * u,
              runSpacing: 6 * u,
              children: [
                for (final m in vision.modos)
                  InkWell(
                    onTap: vision.modoPending == null ? () => pick(m) : null,
                    borderRadius: BorderRadius.circular(AppRadius.md),
                    child: Container(
                      width: 92 * u,
                      padding: EdgeInsets.symmetric(vertical: 7 * u),
                      decoration: BoxDecoration(
                        color: m == current ? AppColors.militaryDark : AppColors.ink.withValues(alpha: 0.6),
                        border: Border.all(color: m == current ? AppColors.military : AppColors.line, width: m == current ? 1.5 : 1),
                        borderRadius: BorderRadius.circular(AppRadius.md),
                      ),
                      child: Column(
                        children: [
                          Text('${VisionMode.emoji(m)} ${VisionMode.label(m)}',
                              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: m == current ? AppColors.text1 : AppColors.text2)),
                          SizedBox(height: 2 * u),
                          vision.modoPending == m
                              ? SizedBox(width: 10 * u, height: 10 * u, child: const CircularProgressIndicator(strokeWidth: 1.2))
                              : Text(VisionMode.speed(m), style: AppText.label.copyWith(fontSize: 9, color: m == current ? AppColors.olive : AppColors.text3)),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
            if (current != null) ...[
              SizedBox(height: 4 * u),
              Text(VisionMode.detail(current), style: const TextStyle(fontSize: 10, color: AppColors.text3)),
            ],
          ],
        );
      },
    );
  }
}

/// Banner rojo "🔥 FUEGO DETECTADO" (solo en modo IA y mientras la IA vea fuego).
class FireBanner extends StatelessWidget {
  const FireBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final vision = context.watch<AppState>().vision;
    return ListenableBuilder(
      listenable: vision,
      builder: (context, _) {
        if (!vision.fire) return const SizedBox.shrink();
        final best = vision.fireConfidence;
        final u = context.u;
        return Container(
          margin: EdgeInsets.only(top: 36 * u),
          padding: EdgeInsets.symmetric(horizontal: 14 * u, vertical: 6 * u),
          decoration: BoxDecoration(
            color: const Color(0xE6B4231B),
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(color: const Color(0xFFFF6A50)),
            boxShadow: const [BoxShadow(color: Color(0x88FF2A10), blurRadius: 18)],
          ),
          child: Text(
            '🔥 FUEGO DETECTADO${best == null ? '' : '  ${(best * 100).round()} %'}',
            style: TextStyle(fontFamily: AppFonts.mono, fontSize: 13 * (u > 1 ? 1.1 : 1), fontWeight: FontWeight.w700, color: Colors.white, letterSpacing: 1.5),
          ),
        );
      },
    );
  }
}

/// Selector de fuente de CAM 2: "RTSP" (cámara directa) / "VISIÓN IA".
/// Sin la PC de visión, IA sale deshabilitada con "PC de visión no
/// disponible". Durante una grabación con CAM 2 no se puede cambiar.
class Cam2SourceSelector extends StatefulWidget {
  /// Versión chica para encima del video (solo los dos botones).
  final bool compact;
  const Cam2SourceSelector({super.key, this.compact = false});

  @override
  State<Cam2SourceSelector> createState() => _Cam2SourceSelectorState();
}

class _Cam2SourceSelectorState extends State<Cam2SourceSelector> {
  @override
  void initState() {
    super.initState();
    // Al abrir la pantalla se pregunta de una vez (además del timer de 5 s).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<AppState>().vision.checkHealth();
    });
  }

  @override
  Widget build(BuildContext context) {
    final u = context.u;
    final state = context.watch<AppState>();
    final vision = state.vision;
    return ListenableBuilder(
      listenable: vision,
      builder: (context, _) {
        final locked = state.cam2Recording;
        final iaOk = vision.available;
        Future<void> pick(bool ia) async {
          final msg = await state.setCam2Ia(ia);
          if (msg != null && context.mounted) showAppToast(context, msg);
        }

        Widget seg(String label, IconData icon, bool selected, bool enabled, VoidCallback onTap) => InkWell(
              onTap: enabled && !selected ? onTap : null,
              borderRadius: BorderRadius.circular(AppRadius.sm),
              child: Container(
                padding: EdgeInsets.symmetric(horizontal: (widget.compact ? 7 : 10) * u, vertical: (widget.compact ? 3 : 6) * u),
                decoration: BoxDecoration(
                  color: selected ? AppColors.militaryDark : AppColors.ink.withValues(alpha: 0.7),
                  border: Border.all(color: selected ? AppColors.military : AppColors.line),
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
                child: Opacity(
                  opacity: enabled || selected ? 1 : 0.4,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(icon, size: (widget.compact ? 11 : 14) * u, color: selected ? AppColors.olive : AppColors.text2),
                      SizedBox(width: 5 * u),
                      Text(label, style: AppText.label.copyWith(fontSize: widget.compact ? 8.5 : 10, color: selected ? AppColors.text1 : AppColors.text2)),
                    ],
                  ),
                ),
              ),
            );

        final buttons = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            seg(widget.compact ? 'RTSP' : 'CÁMARA DIRECTA (RTSP)', Icons.videocam_outlined, !vision.useIa, !locked, () => pick(false)),
            SizedBox(width: 4 * u),
            seg('VISIÓN IA', Icons.local_fire_department_outlined, vision.useIa, iaOk && !locked, () => pick(true)),
          ],
        );
        if (widget.compact) {
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              buttons,
              if (vision.iaActive) ...[SizedBox(width: 4 * u), const VisionModeSelector(compact: true)],
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            buttons,
            if (vision.iaActive) ...[SizedBox(height: 8 * u), const VisionModeSelector()],
            SizedBox(height: 4 * u),
            Text(
              locked
                  ? 'Grabando: la fuente no se puede cambiar hasta detener el video'
                  : (!iaOk ? (vision.checked ? 'PC de visión no disponible (${vision.host})' : 'Buscando la PC de visión…') : 'PC de visión en línea · ${vision.host}'),
              style: TextStyle(fontSize: 10, color: !iaOk && !locked ? AppColors.yellow : AppColors.text3),
            ),
          ],
        );
      },
    );
  }
}
