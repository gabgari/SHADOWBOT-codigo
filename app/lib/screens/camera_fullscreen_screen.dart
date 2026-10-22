import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../app_theme.dart';
import '../services/tapo_cam_service.dart';
import '../state/app_state.dart';
import '../state/bot_link.dart';
import '../state/media_library.dart';
import '../widgets/camera_feed.dart';
import '../widgets/camera_filters.dart';
import '../widgets/common.dart';
import '../widgets/hud.dart';
import '../widgets/vision_widgets.dart';
import 'multimedia_screen.dart' show RecBadge;

/// Pantalla completa de manejo (ver `firmware/ESTILO/PANTALLA COMPLETA.jpg`):
/// la cámara ocupa todo y encima flotan los mandos — brazo (ejes X/Y),
/// joystick de manejo, velocidad, captura, gas, la otra cámara en
/// miniatura y los filtros B/N · IR · VERDE. Con el botón de gota de la
/// barra superior el usuario elige qué tan transparentes quedan los mandos
/// (se guarda en el teléfono).
class CameraFullscreenScreen extends StatefulWidget {
  final AiCameraSource source;
  const CameraFullscreenScreen({super.key, required this.source});

  @override
  State<CameraFullscreenScreen> createState() => _CameraFullscreenScreenState();
}

class _CameraFullscreenScreenState extends State<CameraFullscreenScreen> {
  // La cámara grande es la "principal" de la app: así el mando (L1) o la
  // consola la cambian aquí también.
  AiCameraSource get _main => _state.primaryCamera;
  late final AppState _state;

  AiCameraSource get _other => _main == AiCameraSource.tapoCam ? AiCameraSource.esp32cam : AiCameraSource.tapoCam;

  /// Barra de "transparencia de los mandos" abierta.
  bool _showOpacity = false;

  @override
  void initState() {
    super.initState();
    _state = context.read<AppState>();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _state.setFullscreenOpen(true);
      if (_state.primaryCamera != widget.source) _state.setPrimaryCamera(widget.source);
    });
  }

  @override
  void dispose() {
    _state.releaseMove();
    WidgetsBinding.instance.addPostFrameCallback((_) => _state.setFullscreenOpen(false));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final u = context.u;
    final state = context.watch<AppState>();
    final link = context.watch<BotLink>();
    final filter = state.filterOf(_main);
    final gas = state.gasReadings['mq2']!;
    final gasAlert = gas.isWarn;
    final locked = state.controlLocked;
    final ui = state.fsControlsOpacity;
    // Los mandos flotantes con la transparencia que eligió el usuario.
    Widget dim(Widget child) => Opacity(opacity: ui, child: child);

    return Scaffold(
      backgroundColor: AppColors.ink,
      body: LayoutBuilder(builder: (context, c) {
        final pipW = (c.maxWidth * 0.27).clamp(150.0, 380.0);
        // Teléfono acostado: el gas en una sola línea para que no
        // choquen con la miniatura, y joystick un poco más chico.
        final short = c.maxHeight < 480;
        return Stack(
          fit: StackFit.expand,
          children: [
            CameraFeed(source: _main, fit: BoxFit.cover),
            const ViewfinderOverlay(),
            // Degradados para que los mandos se lean sobre cualquier imagen.
            const IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: [Color(0xAA050607), Color(0x00050607), Color(0x00050607), Color(0x88050607)],
                    stops: [0, 0.28, 0.72, 1],
                  ),
                ),
              ),
            ),

            // ---- Barra superior ----
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                bottom: false,
                child: Container(
                  height: 40 * u,
                  padding: EdgeInsets.symmetric(horizontal: 14 * u),
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xCC050607), Color(0x00050607)]),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.hub_outlined, size: 18 * u, color: AppColors.text2),
                      SizedBox(width: 10 * u),
                      Text('SHADOW BOT', style: AppText.topbarTitle.copyWith(fontSize: 13)),
                      Text('  /  NAVEGACIÓN', style: AppText.topbarTitle.copyWith(fontSize: 13, color: AppColors.text2)),
                      const Spacer(),
                      StatusDot(color: link.estado != null ? AppColors.olive : AppColors.text3, size: 6),
                      SizedBox(width: 8 * u),
                      Text(link.estado != null ? 'EN LÍNEA' : 'SIN ENLACE', style: AppText.label.copyWith(color: AppColors.text1, fontSize: 10)),
                      SizedBox(width: 16 * u),
                      Text('PING ${link.rttMs ?? '—'} ms', style: AppText.label.copyWith(color: AppColors.text1, fontSize: 10)),
                      if (c.maxWidth > 700) ...[
                        SizedBox(width: 16 * u),
                        Text('RSSI ${link.estado?.rssi ?? '—'} dBm', style: AppText.label.copyWith(color: AppColors.text1, fontSize: 10)),
                      ],
                      SizedBox(width: 16 * u),
                      Text('MODO ${BotLink.modeLabel(link.botMode)}', style: AppText.label.copyWith(color: AppColors.text1, fontSize: 10)),
                      SizedBox(width: 16 * u),
                      HudClock(style: AppText.value.copyWith(fontSize: 12)),
                      SizedBox(width: 12 * u),
                      Builder(builder: (context) {
                        final tapo = context.watch<TapoCamService>();
                        return HudIconButton(
                          icon: tapo.muted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
                          size: 30,
                          active: !tapo.muted,
                          tooltip: tapo.muted ? 'Activar sonido de la cámara' : 'Silenciar la cámara',
                          onTap: tapo.toggleMute,
                        );
                      }),
                      SizedBox(width: 8 * u),
                      HudIconButton(
                        icon: Icons.opacity_rounded,
                        size: 30,
                        active: _showOpacity,
                        tooltip: 'Transparencia de los botones',
                        onTap: () => setState(() => _showOpacity = !_showOpacity),
                      ),
                      SizedBox(width: 8 * u),
                      HudIconButton(icon: Icons.close_rounded, size: 30, tooltip: 'Salir', onTap: () => Navigator.of(context).pop()),
                    ],
                  ),
                ),
              ),
            ),

            // ---- Etiqueta de cámara ----
            Positioned(
              top: 50 * u,
              left: 18 * u,
              child: dim(Row(
                children: [
                  HudChip(text: cameraTitle(_main), icon: Icons.photo_camera_outlined, dot: CameraFeed.isLive(context, _main) ? AppColors.olive : AppColors.text3),
                  SizedBox(width: 8 * u),
                  RecBadge(source: _main, showCam: false),
                  const RecBadge.dual(),
                  if (_main == AiCameraSource.tapoCam) ...[SizedBox(width: 8 * u), const Cam2SourceSelector(compact: true)],
                ],
              )),
            ),

            // ---- Columna izquierda: brazo + manejo + velocidad + captura ----
            Positioned(
              left: 18 * u,
              top: 92 * u,
              bottom: 14 * u,
              width: 190 * u,
              child: Opacity(
                opacity: (locked ? 0.4 : 1) * ui,
                child: IgnorePointer(
                  ignoring: locked,
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _AxisRow(
                          icon: Icons.swap_horiz_rounded,
                          label: 'EJE X · PAN',
                          degrees: (state.armPan * 1.8).round(),
                          value: state.armPan,
                          onChanged: (v) => state.setArmAngles(v, state.armTilt),
                        ),
                        SizedBox(height: 10 * u),
                        Padding(
                          padding: EdgeInsets.only(left: 8 * u),
                          child: DriveJoystick(size: short ? 112 : 140, active: state.pressedMove, onDrive: state.holdMove, onRelease: state.releaseMove),
                        ),
                        SizedBox(height: 10 * u),
                        _AxisRow(
                          icon: Icons.swap_vert_rounded,
                          label: 'EJE Y · TILT',
                          degrees: (state.armTilt * 1.8).round(),
                          value: state.armTilt,
                          onChanged: (v) => state.setArmAngles(state.armPan, v),
                        ),
                        SizedBox(height: 12 * u),
                        Row(
                          children: [
                            Icon(Icons.open_with_rounded, size: 15 * u, color: AppColors.text2),
                            SizedBox(width: 8 * u),
                            Text('VELOCIDAD', style: AppText.label.copyWith(fontSize: 9)),
                            const Spacer(),
                            Text('${state.speed}%', style: AppText.value.copyWith(fontSize: 12)),
                          ],
                        ),
                        SizedBox(height: 24 * u, child: Slider(value: state.speed.toDouble(), min: 0, max: 100, onChanged: (v) => state.setSpeed(v.round()))),
                        SizedBox(height: 8 * u),
                        Row(
                          children: [
                            HudIconButton(
                              icon: Icons.photo_camera_outlined,
                              size: 42,
                              round: true,
                              tooltip: 'Captura',
                              onTap: state.capturingPhoto
                                  ? null
                                  : () async {
                                      final msg = await state.takePhoto(source: _main);
                                      if (context.mounted) showAppToast(context, msg);
                                    },
                            ),
                            SizedBox(width: 10 * u),
                            Builder(builder: (context) {
                              context.watch<MediaLibrary>();
                              final recording = state.videoRecording;
                              return HudIconButton(
                                icon: recording ? Icons.stop_circle_outlined : Icons.fiber_manual_record_rounded,
                                size: 42,
                                round: true,
                                danger: recording,
                                tooltip: recording ? 'Detener video' : (state.recordBoth ? 'Grabar CAM 1 + CAM 2' : 'Grabar video'),
                                onTap: state.videoToggling
                                    ? null
                                    : () async {
                                        // La cámara grande ES la principal (ver _main).
                                        final msg = await state.toggleRecording();
                                        if (context.mounted) showAppToast(context, msg);
                                      },
                              );
                            }),
                            SizedBox(width: 10 * u),
                            HudIconButton(icon: Icons.error_outline_rounded, size: 42, round: true, danger: true, tooltip: 'Paro de emergencia', onTap: state.emergencyStop),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),

            // ---- Derecha arriba: filtro + gas ----
            Positioned(
              top: 50 * u,
              right: 18 * u,
              child: dim(Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  HudChip(text: 'Filtro: ${filter.label}', icon: Icons.filter_alt_outlined),
                  SizedBox(height: 10 * u),
                  if (short)
                    Container(
                      padding: EdgeInsets.symmetric(horizontal: 10 * u, vertical: 6 * u),
                      decoration: BoxDecoration(
                        color: AppColors.ink.withValues(alpha: 0.72),
                        border: Border.all(color: AppColors.line),
                        borderRadius: BorderRadius.circular(AppRadius.md),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('MQ-2 ', style: AppText.label.copyWith(fontSize: 8.5)),
                          Text(gas.value.toStringAsFixed(0).padLeft(3, '0'), style: AppText.value.copyWith(fontSize: 12, color: gasAlert ? AppColors.red : null)),
                          SizedBox(width: 6 * u),
                          StatusDot(color: gasAlert ? AppColors.red : AppColors.olive, size: 5),
                        ],
                      ),
                    )
                  else
                  Container(
                    width: 170 * u,
                    padding: EdgeInsets.all(12 * u),
                    decoration: BoxDecoration(
                      color: AppColors.ink.withValues(alpha: 0.72),
                      border: Border.all(color: AppColors.line),
                      borderRadius: BorderRadius.circular(AppRadius.md),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('MQ-2 · ÍNDICE DE GAS', style: AppText.label.copyWith(fontSize: 8.5)),
                        SizedBox(height: 4 * u),
                        Row(
                          children: [
                            Text(gas.value.toStringAsFixed(0).padLeft(3, '0'), style: AppText.value.copyWith(fontSize: 17, color: gasAlert ? AppColors.red : null)),
                            const Spacer(),
                            StatusDot(color: gasAlert ? AppColors.red : AppColors.olive, size: 6),
                            SizedBox(width: 6 * u),
                            Text(gasAlert ? 'ALERTA' : 'NORMAL', style: AppText.label.copyWith(color: AppColors.text1, fontSize: 9)),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              )),
            ),

            // ---- Derecha abajo: miniatura + filtros ----
            Positioned(
              right: 18 * u,
              bottom: 14 * u,
              width: pipW,
              child: dim(Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  AspectRatio(
                      aspectRatio: 16 / 10,
                      child: GestureDetector(
                        onTap: () => _state.setPrimaryCamera(_other),
                        child: Container(
                          clipBehavior: Clip.antiAlias,
                          decoration: BoxDecoration(border: Border.all(color: AppColors.text3), borderRadius: BorderRadius.circular(AppRadius.lg)),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              CameraFeed(source: _other),
                              Positioned(
                                top: 6 * u,
                                left: 8 * u,
                                child: Text('${cameraTitle(_other)}  ●', style: AppText.label.copyWith(fontSize: 8.5, color: AppColors.text1)),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  SizedBox(height: 10 * u),
                  Container(
                    padding: EdgeInsets.all(4 * u),
                    decoration: BoxDecoration(
                      color: AppColors.ink.withValues(alpha: 0.72),
                      border: Border.all(color: AppColors.line),
                      borderRadius: BorderRadius.circular(30),
                    ),
                    child: Row(
                      children: [
                        for (final m in const [CameraFilterMode.blackWhite, CameraFilterMode.military, CameraFilterMode.nightVision])
                          Expanded(
                            child: InkWell(
                              borderRadius: BorderRadius.circular(30),
                              onTap: () => state.setFilter(_main, filter == m ? CameraFilterMode.none : m),
                              child: Container(
                                padding: EdgeInsets.symmetric(vertical: 8 * u),
                                decoration: BoxDecoration(
                                  color: filter == m ? AppColors.surface2 : null,
                                  border: Border.all(color: filter == m ? AppColors.text3 : Colors.transparent),
                                  borderRadius: BorderRadius.circular(30),
                                ),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(m.icon, size: 13 * u, color: filter == m ? AppColors.text1 : AppColors.text2),
                                    SizedBox(width: 5 * u),
                                    Text(m.short, style: AppText.label.copyWith(fontSize: 9.5, color: filter == m ? AppColors.text1 : AppColors.text2)),
                                  ],
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              )),
            ),

            // ---- Abajo al centro: cámara 01 / 02 ----
            Positioned(
              bottom: 14 * u,
              left: 0,
              right: 0,
              child: Center(
                child: dim(Container(
                  padding: EdgeInsets.all(4 * u),
                  decoration: BoxDecoration(
                    color: AppColors.ink.withValues(alpha: 0.72),
                    border: Border.all(color: AppColors.line),
                    borderRadius: BorderRadius.circular(AppRadius.md),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final src in AiCameraSource.values)
                        InkWell(
                          onTap: () => _state.setPrimaryCamera(src),
                          child: Container(
                            padding: EdgeInsets.symmetric(horizontal: 14 * u, vertical: 7 * u),
                            decoration: BoxDecoration(
                              border: Border(bottom: BorderSide(color: _main == src ? AppColors.text1 : Colors.transparent, width: 1.5)),
                            ),
                            child: Row(
                              children: [
                                StatusDot(color: _main == src ? AppColors.text1 : AppColors.text3, size: 5),
                                SizedBox(width: 8 * u),
                                Text(cameraTitle(src), style: AppText.label.copyWith(fontSize: 10, color: _main == src ? AppColors.text1 : AppColors.text2)),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                )),
              ),
            ),

            // ---- Transparencia de los mandos ----
            if (_showOpacity)
              Positioned(
                top: 46 * u,
                right: 18 * u,
                child: SafeArea(
                  bottom: false,
                  child: _OpacityPanel(
                    value: ui,
                    onChanged: state.setFsControlsOpacity,
                    onClose: () => setState(() => _showOpacity = false),
                  ),
                ),
              ),
          ],
        );
      }),
    );
  }
}

/// Barra para elegir qué tan visibles quedan los botones en pantalla
/// completa: a la izquierda casi transparentes, a la derecha sólidos.
class _OpacityPanel extends StatelessWidget {
  final double value;
  final ValueChanged<double> onChanged;
  final VoidCallback onClose;
  const _OpacityPanel({required this.value, required this.onChanged, required this.onClose});

  @override
  Widget build(BuildContext context) {
    final u = context.u;
    return Container(
      width: 290 * u,
      padding: EdgeInsets.fromLTRB(12 * u, 8 * u, 6 * u, 8 * u),
      decoration: BoxDecoration(
        color: AppColors.ink.withValues(alpha: 0.92),
        border: Border.all(color: AppColors.military),
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.opacity_rounded, size: 14 * u, color: AppColors.olive),
              SizedBox(width: 8 * u),
              Text('VISIBILIDAD DE LOS BOTONES', style: AppText.label.copyWith(fontSize: 9, color: AppColors.text1)),
              const Spacer(),
              Text('${(value * 100).round()}%', style: AppText.value.copyWith(fontSize: 12)),
              SizedBox(width: 4 * u),
              HudIconButton(icon: Icons.close_rounded, size: 24, tooltip: 'Cerrar', onTap: onClose),
            ],
          ),
          Row(
            children: [
              Icon(Icons.visibility_off_outlined, size: 13 * u, color: AppColors.text3),
              Expanded(
                child: SizedBox(
                  height: 28 * u,
                  child: Slider(value: value, min: 0.15, max: 1.0, divisions: 17, onChanged: onChanged),
                ),
              ),
              Icon(Icons.visibility_outlined, size: 13 * u, color: AppColors.text1),
              SizedBox(width: 6 * u),
            ],
          ),
          Wrap(
            spacing: 6 * u,
            children: [
              for (final (label, v) in const [('Tenue', 0.3), ('Media', 0.6), ('Sólida', 1.0)])
                HudChip(text: label, active: (value - v).abs() < 0.03, onTap: () => onChanged(v)),
            ],
          ),
        ],
      ),
    );
  }
}

class _AxisRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final int degrees;
  final int value;
  final ValueChanged<int> onChanged;
  const _AxisRow({required this.icon, required this.label, required this.degrees, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final u = context.u;
    return Row(
      children: [
        Container(
          width: 36 * u,
          height: 36 * u,
          decoration: BoxDecoration(color: AppColors.ink.withValues(alpha: 0.6), shape: BoxShape.circle, border: Border.all(color: AppColors.text3)),
          child: Icon(icon, size: 17 * u, color: AppColors.text1),
        ),
        SizedBox(width: 8 * u),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: AppText.label.copyWith(fontSize: 8.5)),
              Text('$degrees°', style: AppText.value.copyWith(fontSize: 12)),
              SizedBox(height: 20 * u, child: Slider(value: value.toDouble(), min: 0, max: 100, onChanged: (v) => onChanged(v.round()))),
            ],
          ),
        ),
      ],
    );
  }
}

/// Abre la pantalla completa con [source] como cámara principal, sobre el
/// Navigator raíz (tapa también la barra superior de la app).
Future<void> openCameraFullscreen(BuildContext context, AiCameraSource source) {
  return Navigator.of(context, rootNavigator: true).push(
    MaterialPageRoute(builder: (_) => CameraFullscreenScreen(source: source), fullscreenDialog: true),
  );
}
