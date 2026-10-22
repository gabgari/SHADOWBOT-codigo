import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:provider/provider.dart';

import '../app_theme.dart';
import '../services/media_files/media_files.dart';
import '../state/app_state.dart';
import '../state/media_library.dart';
import '../widgets/camera_filters.dart';
import '../widgets/common.dart';
import '../widgets/hud.dart';
import '../widgets/top_bar.dart';

/// Sección MULTIMEDIA: todas las fotos y videos de CAM 1 y CAM 2, con el
/// filtro que tenía la cámara al capturar (ya quemado en el archivo).
class MultimediaScreen extends StatefulWidget {
  const MultimediaScreen({super.key});

  @override
  State<MultimediaScreen> createState() => _MultimediaScreenState();
}

class _MultimediaScreenState extends State<MultimediaScreen> {
  int tab = 0; // 0 todo, 1 fotos, 2 videos

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final media = context.watch<MediaLibrary>();
    final u = context.u;
    final list = switch (tab) {
      1 => media.photos,
      2 => media.videos,
      _ => media.items,
    };

    return Column(
      children: [
        ScreenTopBar(title: 'Multimedia', onBack: () => state.showScreen(ScreenNames.camara)),
        Padding(
          padding: EdgeInsets.fromLTRB(20 * u, 0, 20 * u, 12 * u),
          child: Row(
            children: [
              HudChip(text: 'Todo · ${media.items.length}', icon: Icons.perm_media_outlined, active: tab == 0, onTap: () => setState(() => tab = 0)),
              SizedBox(width: 6 * u),
              HudChip(text: 'Fotos · ${media.photos.length}', icon: Icons.photo_outlined, active: tab == 1, onTap: () => setState(() => tab = 1)),
              SizedBox(width: 6 * u),
              HudChip(text: 'Videos · ${media.videos.length}', icon: Icons.videocam_outlined, active: tab == 2, onTap: () => setState(() => tab = 2)),
              const Spacer(),
              if (media.anyRecording)
                for (final src in AiCameraSource.values)
                  if (media.isRecording(src)) Padding(padding: EdgeInsets.only(left: 6 * u), child: RecBadge(source: src)),
              if (media.isDualRecording) Padding(padding: EdgeInsets.only(left: 6 * u), child: const RecBadge.dual()),
            ],
          ),
        ),
        Expanded(
          child: list.isEmpty
              ? Center(
                  child: Text(
                    switch (tab) {
                      1 => 'Aún no hay fotos — usa "Tomar foto" en Cámaras',
                      2 => 'Aún no hay videos — usa "Grabar video" en Cámaras',
                      _ => 'Aún no hay fotos ni videos',
                    },
                    style: const TextStyle(color: AppColors.text3, fontSize: 12.5),
                  ),
                )
              : LayoutBuilder(builder: (context, c) {
                  final cols = (c.maxWidth / (220 * u)).floor().clamp(2, 6);
                  return GridView.builder(
                    padding: EdgeInsets.fromLTRB(20 * u, 0, 20 * u, 18 * u),
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: cols,
                      crossAxisSpacing: 10 * u,
                      mainAxisSpacing: 10 * u,
                      childAspectRatio: 4 / 3,
                    ),
                    itemCount: list.length,
                    itemBuilder: (context, i) => MediaThumb(item: list[i], onTap: () => openMediaViewer(context, list[i])),
                  );
                }),
        ),
        if (!mediaFilesPersistent)
          Padding(
            padding: EdgeInsets.fromLTRB(20 * u, 0, 20 * u, 12 * u),
            child: const Text(
              'En la versión web las fotos se descargan con el navegador y no se pueden grabar videos.',
              style: TextStyle(fontSize: 10.5, color: AppColors.text3),
            ),
          ),
      ],
    );
  }
}

/// Miniatura de una foto o video (cuadrícula de Multimedia y "Últimas
/// capturas" de Cámaras).
class MediaThumb extends StatelessWidget {
  final MediaItem item;
  final VoidCallback? onTap;
  final bool compact;
  const MediaThumb({super.key, required this.item, this.onTap, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final provider = item.bytes != null
        ? MemoryImage(item.bytes!)
        : (item.isVideo ? (item.thumbPath != null ? mediaImageProvider(item.thumbPath!) : null) : (item.path != null ? mediaImageProvider(item.path!) : null));
    Widget tag(String text, {Color? color}) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.55), borderRadius: BorderRadius.circular(5)),
          child: Text(text, style: TextStyle(fontFamily: AppFonts.mono, fontSize: 9, color: color ?? Colors.white70)),
        );

    return ClipRRect(
      borderRadius: BorderRadius.circular(compact ? 12 : AppRadius.lg),
      child: Material(
        color: AppColors.surface1,
        child: InkWell(
          onTap: onTap,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (provider != null)
                Image(image: ResizeImage(provider, width: 480), fit: BoxFit.cover, gaplessPlayback: true, errorBuilder: (_, _, _) => const _Missing())
              else
                const _Missing(),
              if (item.isVideo)
                Center(
                  child: Container(
                    width: compact ? 24 : 38,
                    height: compact ? 24 : 38,
                    decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.55), shape: BoxShape.circle, border: Border.all(color: Colors.white38)),
                    child: Icon(Icons.play_arrow_rounded, color: Colors.white, size: compact ? 16 : 24),
                  ),
                ),
              if (!compact) ...[
                Positioned(top: 6, left: 6, child: tag(item.camLabel)),
                if (item.filter != CameraFilterMode.none) Positioned(top: 6, right: 6, child: tag(item.filter.short, color: AppColors.olive)),
                Positioned(bottom: 6, left: 6, child: tag(item.timeLabel)),
                if (item.isVideo) Positioned(bottom: 6, right: 6, child: tag(item.durationLabel)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Missing extends StatelessWidget {
  const _Missing();
  @override
  Widget build(BuildContext context) => const ColoredBox(
        color: AppColors.surface2,
        child: Center(child: Icon(Icons.image_not_supported_outlined, color: AppColors.text3, size: 20)),
      );
}

/// Insignia "● REC 00:12" de una grabación en curso.
class RecBadge extends StatelessWidget {
  final AiCameraSource source;
  final bool showCam;

  /// Insignia del video de las 2 cámaras juntas.
  final bool dual;
  const RecBadge({super.key, required this.source, this.showCam = true}) : dual = false;
  const RecBadge.dual({super.key, this.showCam = true})
      : source = AiCameraSource.esp32cam,
        dual = true;

  @override
  Widget build(BuildContext context) {
    final media = context.watch<MediaLibrary>();
    if (dual ? !media.isDualRecording : !media.isRecording(source)) return const SizedBox.shrink();
    final stalled = dual ? media.dualStalled : media.recordingStalled(source);
    final elapsed = dual ? media.dualElapsed : media.recordingElapsed(source);
    final cam = dual ? 'CAM 1+2 ' : (source == AiCameraSource.tapoCam ? 'CAM 2 ' : 'CAM 1 ');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xB80A0A0C),
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: stalled ? AppColors.yellow : Colors.white24),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 6, height: 6, decoration: BoxDecoration(color: stalled ? AppColors.yellow : AppColors.red, shape: BoxShape.circle)),
          const SizedBox(width: 5),
          Text(
            '${showCam ? cam : ''}REC ${formatDuration(elapsed)}${stalled ? ' · SIN VIDEO' : ''}',
            style: const TextStyle(fontFamily: AppFonts.mono, color: Colors.white, fontSize: 10, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}

Future<void> openMediaViewer(BuildContext context, MediaItem item) {
  return Navigator.of(context, rootNavigator: true).push(
    MaterialPageRoute(builder: (_) => MediaViewerScreen(item: item), fullscreenDialog: true),
  );
}

/// Visor a pantalla completa: foto con zoom, o reproductor del video.
class MediaViewerScreen extends StatelessWidget {
  final MediaItem item;
  const MediaViewerScreen({super.key, required this.item});

  Future<void> _delete(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface1,
        title: Text(item.isVideo ? 'Borrar video' : 'Borrar foto', style: const TextStyle(color: AppColors.text1, fontSize: 16)),
        content: const Text('Se borra el archivo del teléfono. No se puede deshacer.', style: TextStyle(color: AppColors.text2, fontSize: 13)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Borrar', style: TextStyle(color: AppColors.red))),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    await context.read<MediaLibrary>().delete(item);
    if (context.mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final u = context.u;
    final info = [
      item.camLabel,
      item.dateLabel,
      if (item.filter != CameraFilterMode.none) 'Filtro ${item.filter.short}',
      if (item.width > 0) '${item.width}×${item.height}',
      if (item.isVideo && item.durationMs > 0) '${item.durationLabel} · ${(item.frames * 1000 / item.durationMs).toStringAsFixed(1)} fps',
      if (item.sizeBytes > 0) formatBytes(item.sizeBytes),
    ].join('  ·  ');

    return Scaffold(
      backgroundColor: AppColors.ink,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(12 * u, 8 * u, 12 * u, 8 * u),
              child: Row(
                children: [
                  HudIconButton(icon: Icons.close_rounded, size: 34, onTap: () => Navigator.pop(context)),
                  SizedBox(width: 12 * u),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(item.isVideo ? 'VIDEO' : 'FOTO', style: AppText.topbarTitle),
                        Text(info, style: AppText.label.copyWith(fontSize: 9.5, color: AppColors.text2), overflow: TextOverflow.ellipsis),
                      ],
                    ),
                  ),
                  if (item.path != null && mediaFilesPersistent)
                    HudIconButton(
                      icon: Icons.folder_outlined,
                      size: 34,
                      tooltip: 'Ubicación del archivo',
                      onTap: () => showAppToast(context, item.path!),
                    ),
                  SizedBox(width: 8 * u),
                  if (mediaFilesPersistent) HudIconButton(icon: Icons.delete_outline_rounded, size: 34, danger: true, tooltip: 'Borrar', onTap: () => _delete(context)),
                ],
              ),
            ),
            Expanded(child: item.isVideo ? _VideoPlayerView(item: item) : _PhotoView(item: item)),
          ],
        ),
      ),
    );
  }
}

class _PhotoView extends StatelessWidget {
  final MediaItem item;
  const _PhotoView({required this.item});

  @override
  Widget build(BuildContext context) {
    final provider = item.bytes != null ? MemoryImage(item.bytes!) : (item.path != null ? mediaImageProvider(item.path!) : null);
    if (provider == null) return const _Missing();
    return InteractiveViewer(
      maxScale: 6,
      child: Center(child: Image(image: provider, fit: BoxFit.contain, errorBuilder: (_, _, _) => const _Missing())),
    );
  }
}

class _VideoPlayerView extends StatefulWidget {
  final MediaItem item;
  const _VideoPlayerView({required this.item});

  @override
  State<_VideoPlayerView> createState() => _VideoPlayerViewState();
}

class _VideoPlayerViewState extends State<_VideoPlayerView> {
  late final Player _player = Player();
  late final VideoController _controller = VideoController(_player);
  final _subs = <StreamSubscription<dynamic>>[];
  Duration _pos = Duration.zero;
  Duration _dur = Duration.zero;
  bool _playing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _subs
      ..add(_player.stream.position.listen((p) => setState(() => _pos = p)))
      ..add(_player.stream.duration.listen((d) => setState(() => _dur = d)))
      ..add(_player.stream.playing.listen((p) => setState(() => _playing = p)))
      ..add(_player.stream.error.listen((e) => setState(() => _error = e)));
    if (widget.item.path != null) _player.open(Media(widget.item.path!));
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final u = context.u;
    final total = _dur > Duration.zero ? _dur : Duration(milliseconds: widget.item.durationMs);
    final max = total.inMilliseconds.toDouble().clamp(1.0, double.infinity);
    return Column(
      children: [
        Expanded(
          child: GestureDetector(
            onTap: _player.playOrPause,
            child: Stack(
              fit: StackFit.expand,
              children: [
                // El filtro ya viene quemado en los frames: aquí se muestra tal cual.
                Video(controller: _controller, controls: NoVideoControls, fit: BoxFit.contain, fill: AppColors.ink),
                if (_error != null)
                  Center(child: Text('No se pudo reproducir: $_error', style: const TextStyle(color: AppColors.red, fontSize: 12))),
              ],
            ),
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(12 * u, 4 * u, 16 * u, 10 * u),
          child: Row(
            children: [
              HudIconButton(icon: _playing ? Icons.pause_rounded : Icons.play_arrow_rounded, size: 38, round: true, onTap: _player.playOrPause),
              SizedBox(width: 10 * u),
              Text(formatDuration(_pos), style: AppText.value.copyWith(fontSize: 11)),
              Expanded(
                child: Slider(
                  value: _pos.inMilliseconds.toDouble().clamp(0, max),
                  max: max,
                  onChanged: (v) => _player.seek(Duration(milliseconds: v.round())),
                ),
              ),
              Text(formatDuration(total), style: AppText.value.copyWith(fontSize: 11)),
            ],
          ),
        ),
      ],
    );
  }
}
