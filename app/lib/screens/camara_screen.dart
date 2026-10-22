import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_theme.dart';
import '../models/node_link.dart';
import '../services/device_config.dart';
import '../services/tapo_cam_service.dart';
import '../state/app_state.dart';
import '../state/assistant_state.dart';
import '../state/media_library.dart';
import '../widgets/camera_feed.dart';
import '../widgets/camera_filters.dart';
import '../widgets/common.dart';
import '../widgets/corridor_placeholder.dart';
import '../widgets/top_bar.dart';
import '../widgets/vision_widgets.dart';
import 'camera_fullscreen_screen.dart';
import 'multimedia_screen.dart';

class CamaraScreen extends StatefulWidget {
  const CamaraScreen({super.key});

  @override
  State<CamaraScreen> createState() => _CamaraScreenState();
}

class _CamaraScreenState extends State<CamaraScreen> {
  bool _flash = false;

  Future<void> _tomarFoto(AppState state, AiCameraSource source) async {
    setState(() => _flash = true);
    Future.delayed(const Duration(milliseconds: 350), () {
      if (mounted) setState(() => _flash = false);
    });
    final msg = await state.takePhoto(source: source);
    if (mounted) showAppToast(context, msg);
  }

  Future<void> _toggleRecording(AppState state, AiCameraSource source) async {
    final msg = await state.toggleRecording(source: source);
    if (mounted) showAppToast(context, msg);
  }

  void _analizarCon(BuildContext context, AppState state, AiCameraSource source) {
    final assistant = context.read<AssistantState>();
    if (assistant.isBusy) return;
    state.setAiCameraSource(source);
    assistant.analyzeCurrentFrame();
    showAppToast(context, 'Analizando con ${source == AiCameraSource.tapoCam ? 'CAM 2' : 'CAM 1'}…');
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final config = context.watch<DeviceConfig>();
    final tapoCam = context.watch<TapoCamService>();
    final media = context.watch<MediaLibrary>();
    final camLink = config.of(HardwareNode.esp32cam);
    final tapoLink = config.of(HardwareNode.tapoCam);

    // Idempotente: si ya está conectada a esta misma URL no hace nada. Se
    // dispara desde build a propósito (en vez de un StatefulWidget aparte
    // por cámara) para que, en cuanto se guarda/cambia la URL en
    // Conexiones, el stream se abra solo sin tener que salir y volver a
    // entrar a esta pantalla.
    if (tapoLink.host.isNotEmpty) {
      tapoCam.ensureConnected();
    }

    return Column(
      children: [
        ScreenTopBar(title: 'Cámara', onBack: () => state.showScreen(ScreenNames.control)),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
            children: [
              _CameraPickersCard(state: state),
              const SizedBox(height: 16),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            const Text(
                              'CAM 1',
                              style: TextStyle(fontSize: 12.5, color: AppColors.text2, fontWeight: FontWeight.w500),
                            ),
                            const Spacer(),
                            _PrimaryBadge(
                              isPrimary: state.primaryCamera == AiCameraSource.esp32cam,
                              onTap: () => state.setPrimaryCamera(AiCameraSource.esp32cam),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: AspectRatio(
                            // 3/4: el ESP32-CAM va montado de lado (ver mjpeg_view.dart),
                            // así que el video ya rotado queda apaisado -> el recuadro
                            // que lo contiene es alto, para no recortarlo de más.
                            aspectRatio: 16 / 10,
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                Container(color: const Color(0xFF0A0A0C)),
                                if (camLink.isOnline && state.camService.streamUri != null)
                                  CameraFeed(source: AiCameraSource.esp32cam, paused: state.fullscreenOpen)
                                else
                                  const CorridorPlaceholder(),
                                AnimatedOpacity(
                                  opacity: _flash ? 0.9 : 0,
                                  duration: const Duration(milliseconds: 150),
                                  child: Container(color: Colors.white),
                                ),
                                if (camLink.isOnline && state.camService.streamUri != null) ...[
                                  Positioned(top: 10, left: 10, child: _AnalyzeIconButton(onTap: () => _analizarCon(context, state, AiCameraSource.esp32cam))),
                                  Positioned(top: 10, right: 10, child: _FullscreenButton(onTap: () => openCameraFullscreen(context, AiCameraSource.esp32cam))),
                                ],
                                const Positioned(bottom: 9, left: 9, child: RecBadge(source: AiCameraSource.esp32cam, showCam: false)),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),
                        CameraFilterSelector(value: state.esp32Filter, onChanged: (m) => state.setFilter(AiCameraSource.esp32cam, m)),
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            Expanded(
                              child: _RecordButton(media: media, source: AiCameraSource.esp32cam, onTap: () => _toggleRecording(state, AiCameraSource.esp32cam)),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              flex: 2,
                              child: SizedBox(
                                height: 58,
                                child: ElevatedButton(
                                  onPressed: () => _tomarFoto(state, AiCameraSource.esp32cam),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: AppColors.orange,
                                    foregroundColor: AppColors.onAccent,
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                    elevation: 0,
                                  ),
                                  child: const Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Icon(Icons.camera_alt_rounded, size: 20),
                                      SizedBox(height: 4),
                                      Text('Tomar foto', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: _CamButton(icon: Icons.perm_media_rounded, label: 'Multimedia', onTap: () => state.showScreen(ScreenNames.galeria)),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            const Text(
                              'CAM 2',
                              style: TextStyle(fontSize: 12.5, color: AppColors.text2, fontWeight: FontWeight.w500),
                            ),
                            const SizedBox(width: 8),
                            // Punto de estado en vivo, leído directo del reproductor
                            // (no de DeviceConfig): esta cámara ya no se pingea sola
                            // de fondo (ver `AppState._startHealthTimer`), así que un
                            // estado basado en el último ping quedaría desactualizado
                            // en cuanto el usuario entra a mirar el stream real.
                            Container(
                              width: 5,
                              height: 5,
                              decoration: BoxDecoration(
                                color: tapoCam.isPlaying ? AppColors.green : (tapoCam.lastError != null ? AppColors.red : AppColors.text3),
                                shape: BoxShape.circle,
                              ),
                            ),
                            const Spacer(),
                            _PrimaryBadge(
                              isPrimary: state.primaryCamera == AiCameraSource.tapoCam,
                              onTap: () => state.setPrimaryCamera(AiCameraSource.tapoCam),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: AspectRatio(
                            aspectRatio: 16 / 10,
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                Container(color: const Color(0xFF0A0A0C)),
                                if (tapoLink.host.isEmpty) const _TapoEmptyState() else const CameraFeed(source: AiCameraSource.tapoCam),
                                if (tapoLink.host.isNotEmpty) ...[
                                  Positioned(top: 10, left: 10, child: _AnalyzeIconButton(onTap: () => _analizarCon(context, state, AiCameraSource.tapoCam))),
                                  Positioned(
                                    top: 10,
                                    right: 10,
                                    child: Row(
                                      children: [
                                        _RoundIconButton(
                                          icon: tapoCam.muted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
                                          onTap: () => tapoCam.toggleMute(),
                                        ),
                                        const SizedBox(width: 6),
                                        _FullscreenButton(onTap: () => openCameraFullscreen(context, AiCameraSource.tapoCam)),
                                      ],
                                    ),
                                  ),
                                  const Positioned(bottom: 9, left: 9, child: RecBadge(source: AiCameraSource.tapoCam, showCam: false)),
                                ],
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),
                        const Cam2SourceSelector(),
                        const SizedBox(height: 8),
                        if (tapoLink.host.isNotEmpty || state.vision.iaActive)
                          CameraFilterSelector(value: state.tapoFilter, onChanged: (m) => state.setFilter(AiCameraSource.tapoCam, m)),
                        const SizedBox(height: 4),
                        Text(
                          'El micrófono de la Tapo se escucha por la bocina del teléfono (botón de silencio arriba). Hablar por su altavoz no está disponible: TP-Link no expone audio bidireccional por RTSP estándar, solo por su app propia. Los videos se guardan con el filtro elegido, pero sin audio.',
                          style: const TextStyle(fontSize: 10.5, color: AppColors.text3),
                        ),
                        if (tapoLink.host.isNotEmpty || state.vision.iaActive) ...[
                          const SizedBox(height: 16),
                          Row(
                            children: [
                              Expanded(
                                child: _RecordButton(media: media, source: AiCameraSource.tapoCam, onTap: () => _toggleRecording(state, AiCameraSource.tapoCam)),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                flex: 2,
                                child: SizedBox(
                                  height: 58,
                                  child: ElevatedButton(
                                    onPressed: () => _tomarFoto(state, AiCameraSource.tapoCam),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: AppColors.orange,
                                      foregroundColor: AppColors.onAccent,
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                      elevation: 0,
                                    ),
                                    child: const Column(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        Icon(Icons.camera_alt_rounded, size: 20),
                                        SizedBox(height: 4),
                                        Text('Tomar foto', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: _CamButton(icon: Icons.perm_media_rounded, label: 'Multimedia', onTap: () => state.showScreen(ScreenNames.galeria)),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
              const SectionTitle('Video de las 2 cámaras'),
              _DualRecordPanel(state: state, media: media),
              const SectionTitle('Últimas capturas'),
              SizedBox(
                height: 66,
                child: media.items.isEmpty
                    ? const Center(
                        child: Text('Aún no hay capturas', style: TextStyle(color: AppColors.text3, fontSize: 12)),
                      )
                    : ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: media.items.length.clamp(0, 8),
                        separatorBuilder: (_, _) => const SizedBox(width: 8),
                        itemBuilder: (context, i) => SizedBox(
                          width: 88,
                          child: MediaThumb(item: media.items[i], compact: true, onTap: () => openMediaViewer(context, media.items[i])),
                        ),
                      ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Agrupa las 2 elecciones independientes entre ESP32-CAM y Tapo C110:
/// cuál se ve como vista principal en Control (`primaryCamera`, se
/// persiste) y de cuál toma el frame el asistente de IA (`aiCameraSource`,
/// botón "Analizar" / preguntas de voz tipo "¿qué ves?"). Puramente
/// switches de estado en `AppState` — ninguna de las dos cámaras necesita
/// saber de la otra.
class _CameraPickersCard extends StatelessWidget {
  final AppState state;
  const _CameraPickersCard({required this.state});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.surface1,
        border: Border.all(color: AppColors.lineSoft),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        children: [
          _PickerRow(icon: Icons.star_rounded, label: 'Cámara principal:', selected: state.primaryCamera, onChanged: state.setPrimaryCamera),
          const SizedBox(height: 8),
          _PickerRow(icon: Icons.smart_toy_rounded, label: 'IA observa:', selected: state.aiCameraSource, onChanged: state.setAiCameraSource),
        ],
      ),
    );
  }
}

class _PickerRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final AiCameraSource selected;
  final ValueChanged<AiCameraSource> onChanged;
  const _PickerRow({required this.icon, required this.label, required this.selected, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 16, color: AppColors.orange),
        const SizedBox(width: 8),
        Text(
          label,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.text1),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: SegmentedButton<AiCameraSource>(
            segments: const [
              ButtonSegment(
                value: AiCameraSource.esp32cam,
                label: Text('CAM 1', style: TextStyle(fontSize: 11)),
              ),
              ButtonSegment(
                value: AiCameraSource.tapoCam,
                label: Text('CAM 2', style: TextStyle(fontSize: 11)),
              ),
            ],
            selected: {selected},
            onSelectionChanged: (s) => onChanged(s.first),
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
          ),
        ),
      ],
    );
  }
}

/// Chip que muestra si esta cámara es la principal (ver
/// `AppState.primaryCamera`) o, si no lo es, deja marcarla como tal sin
/// tener que subir hasta `_CameraPickersCard`.
class _PrimaryBadge extends StatelessWidget {
  final bool isPrimary;
  final VoidCallback onTap;
  const _PrimaryBadge({required this.isPrimary, required this.onTap});

  @override
  Widget build(BuildContext context) {
    if (isPrimary) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.star_rounded, size: 13, color: AppColors.orange),
            SizedBox(width: 3),
            Text(
              'Principal',
              style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: AppColors.orange),
            ),
          ],
        ),
      );
    }
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.star_border_rounded, size: 13, color: AppColors.text3),
            const SizedBox(width: 3),
            Text(
              'Usar como principal',
              style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600, color: AppColors.text3),
            ),
          ],
        ),
      ),
    );
  }
}

/// Botón redondo para pedirle a la IA que analice el frame de ESTA cámara
/// específicamente (equivalente al botón "Analizar" de Control, pero fija
/// primero `aiCameraSource` a la cámara del bloque donde está este botón).
class _AnalyzeIconButton extends StatelessWidget {
  final VoidCallback onTap;
  const _AnalyzeIconButton({required this.onTap});

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(9),
    child: Container(
      width: 30,
      height: 30,
      decoration: BoxDecoration(
        color: const Color(0xB80A0A0C),
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: Colors.white24),
      ),
      child: const Icon(Icons.smart_toy_rounded, size: 16, color: AppColors.orange),
    ),
  );
}

class _TapoEmptyState extends StatelessWidget {
  const _TapoEmptyState();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 24),
        child: Text(
          'Sin vincular — agrega la URL RTSP en Sistema > Conexiones',
          textAlign: TextAlign.center,
          style: TextStyle(color: AppColors.text3, fontSize: 12.5, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}

class _FullscreenButton extends StatelessWidget {
  final VoidCallback onTap;
  const _FullscreenButton({required this.onTap});

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(9),
    child: Container(
      width: 30,
      height: 30,
      decoration: BoxDecoration(
        color: const Color(0xB80A0A0C),
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: Colors.white24),
      ),
      child: const Icon(Icons.fullscreen_rounded, size: 17, color: Colors.white),
    ),
  );
}

class _RoundIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _RoundIconButton({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(9),
    child: Container(
      width: 30,
      height: 30,
      decoration: BoxDecoration(
        color: const Color(0xB80A0A0C),
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: Colors.white24),
      ),
      child: Icon(icon, size: 16, color: Colors.white),
    ),
  );
}

class _CamButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool danger;
  const _CamButton({required this.icon, required this.label, required this.onTap, this.danger = false});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 58,
      child: OutlinedButton(
        onPressed: onTap,
        style: OutlinedButton.styleFrom(
          backgroundColor: AppColors.surface2,
          foregroundColor: danger ? AppColors.red : AppColors.text1,
          side: BorderSide(color: danger ? AppColors.red : AppColors.line),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 18),
            const SizedBox(height: 6),
            Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}

/// Grabar CAM 1 + CAM 2 en un solo video (lado a lado) y si el botón
/// GRABAR de la consola, la pantalla completa y el mando graban las 2.
class _DualRecordPanel extends StatelessWidget {
  final AppState state;
  final MediaLibrary media;
  const _DualRecordPanel({required this.state, required this.media});

  @override
  Widget build(BuildContext context) {
    final rec = media.isDualRecording;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: _CamButton(
                icon: rec ? Icons.stop_circle_rounded : Icons.video_camera_back_outlined,
                label: rec ? 'Detener CAM 1+2 ${formatDuration(media.dualElapsed)}' : 'Grabar CAM 1 + CAM 2',
                danger: rec,
                onTap: media.isDualToggling
                    ? null
                    : () async {
                        final msg = await media.toggleDualRecording();
                        state.addAlert(AppColors.green, msg);
                        if (context.mounted) showAppToast(context, msg);
                      },
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            const Expanded(
              child: Text(
                'Botón GRABAR de la consola, pantalla completa y mando (L2 + Share) graban las 2 cámaras juntas',
                style: TextStyle(fontSize: 11.5, color: AppColors.text1),
              ),
            ),
            Switch(value: state.recordBoth, onChanged: state.setRecordBoth),
          ],
        ),
        const Text(
          'Sale un solo video: CAM 1 a la izquierda y CAM 2 a la derecha, cada una con su filtro. CAM 1 se graba mientras su video esté en pantalla.',
          style: TextStyle(fontSize: 10.5, color: AppColors.text3),
        ),
      ],
    );
  }
}

/// "Grabar video" / "Detener 00:12" para una cámara.
class _RecordButton extends StatelessWidget {
  final MediaLibrary media;
  final AiCameraSource source;
  final VoidCallback onTap;
  const _RecordButton({required this.media, required this.source, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final rec = media.isRecording(source);
    return _CamButton(
      icon: rec ? Icons.stop_circle_rounded : Icons.fiber_manual_record_rounded,
      label: rec ? 'Detener ${formatDuration(media.recordingElapsed(source))}' : 'Grabar video',
      danger: rec,
      onTap: media.isToggling(source) ? null : onTap,
    );
  }
}
