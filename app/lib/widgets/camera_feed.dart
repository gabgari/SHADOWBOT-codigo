import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:provider/provider.dart';

import '../app_theme.dart';
import '../models/node_link.dart';
import '../services/device_config.dart';
import '../services/tapo_cam_service.dart';
import '../state/app_state.dart';
import 'camera_filters.dart';
import 'mjpeg_view.dart';
import 'vision_widgets.dart';

/// Nombre corto de cada cámara en la consola.
String cameraTitle(AiCameraSource src) => src == AiCameraSource.tapoCam ? 'CAM 2' : 'CAM 1';

/// Video en vivo de una cámara (ESP32-CAM por MJPEG o Tapo C110 por RTSP)
/// con el filtro que tenga elegido en [AppState]. Sin vínculo muestra
/// "SIN SEÑAL". [paused] suelta el stream (el ESP32-CAM solo sirve uno).
class CameraFeed extends StatelessWidget {
  final AiCameraSource source;
  final BoxFit fit;
  final bool paused;
  const CameraFeed({super.key, required this.source, this.fit = BoxFit.cover, this.paused = false});

  static bool isLive(BuildContext context, AiCameraSource source) {
    final state = context.read<AppState>();
    final config = context.read<DeviceConfig>();
    if (source == AiCameraSource.tapoCam) {
      final vision = context.read<AppState>().vision;
      return vision.iaActive ? vision.hasFreshFrame() : context.read<TapoCamService>().isPlaying;
    }
    return config.of(HardwareNode.esp32cam).isOnline && state.camService.streamUri != null;
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final config = context.watch<DeviceConfig>();
    final filter = state.filterOf(source);

    Widget video;
    if (source == AiCameraSource.tapoCam && state.vision.iaActive) {
      // VISIÓN IA: el video ya procesado por YOLO en la PC (con recuadros).
      video = VisionView(fit: fit);
    } else if (source == AiCameraSource.tapoCam) {
      final tapo = context.watch<TapoCamService>();
      final host = config.of(HardwareNode.tapoCam).host;
      if (host.isEmpty) {
        video = const NoSignal(detail: 'Agrega la URL RTSP en Sistema › Conexiones');
      } else {
        tapo.ensureConnected(); // idempotente
        video = Video(controller: tapo.controller, controls: NoVideoControls, fit: fit);
      }
    } else {
      final link = config.of(HardwareNode.esp32cam);
      final uri = state.camService.streamUri;
      if (paused) {
        video = const NoSignal(detail: 'En pantalla completa');
      } else if (link.isOnline && uri != null) {
        video = MjpegView(uri: uri, onFrame: state.camService.pushFrame);
      } else {
        video = NoSignal(detail: link.host.isEmpty ? 'Agrega la IP en Sistema › Conexiones' : 'CAM 1 sin respuesta');
      }
    }
    return ColoredBox(color: AppColors.ink, child: CameraFilterOverlay(mode: filter, child: video));
  }
}

/// Fondo de cámara sin señal: ruido de líneas tenues + texto.
class NoSignal extends StatelessWidget {
  final String detail;
  const NoSignal({super.key, this.detail = ''});

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        CustomPaint(painter: _ScanPainter()),
        Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.videocam_off_outlined, color: AppColors.text3, size: 22),
              const SizedBox(height: 6),
              const Text('SIN SEÑAL', style: TextStyle(fontFamily: AppFonts.mono, fontSize: 12, color: AppColors.text2, letterSpacing: 3)),
              if (detail.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(detail, textAlign: TextAlign.center, style: const TextStyle(fontSize: 10, color: AppColors.text3)),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _ScanPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = AppColors.ink);
    final p = Paint()..color = const Color(0x08FFFFFF);
    for (double y = 0; y < size.height; y += 3) {
      canvas.drawRect(Rect.fromLTWH(0, y, size.width, 1), p);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
