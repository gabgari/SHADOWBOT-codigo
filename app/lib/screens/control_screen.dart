import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_theme.dart';
import '../models/node_link.dart';
import '../services/device_config.dart';
import '../services/tapo_cam_service.dart';
import '../state/app_state.dart';
import '../state/assistant_state.dart';
import '../state/auto_route.dart';
import '../state/bot_link.dart';
import '../state/media_library.dart';
import '../widgets/camera_feed.dart';
import '../widgets/camera_filters.dart';
import '../widgets/common.dart';
import '../widgets/modes_card.dart';
import '../widgets/vision_widgets.dart';
import '../widgets/hud.dart';
import 'camera_fullscreen_screen.dart';
import 'conexiones_screen.dart';
import 'gemini_log_screen.dart';
import 'voice_commands_help_screen.dart';

/// Consola de NAVEGACIÓN — la interfaz de inicio de SHADOW BOT (ver
/// `firmware/ESTILO/INTERFAZ DE INICIO.jpg`).
///
///   izquierda : filtros de cámara · brazo 2 ejes · modo / bailes
///   centro    : las 2 cámaras (o una + miniatura si no caben)
///   derecha   : telemetría · movimiento · control (velocidad, motores)
///   abajo     : captura · pantalla completa · estado · asistente de voz
///
/// Se acomoda sola al tamaño: en tablets todo crece (ver `context.u`) y en
/// pantallas angostas pasa a una sola columna con scroll.
class ControlScreen extends StatefulWidget {
  const ControlScreen({super.key});

  @override
  State<ControlScreen> createState() => _ControlScreenState();
}

class _ControlScreenState extends State<ControlScreen> {
  /// A qué cámara se le aplica la lista de filtros (0 = principal, 1 = la otra).
  int _filterTarget = 0;

  AiCameraSource _other(AiCameraSource s) => s == AiCameraSource.tapoCam ? AiCameraSource.esp32cam : AiCameraSource.tapoCam;

  @override
  Widget build(BuildContext context) {
    final u = context.u;
    final state = context.watch<AppState>();
    final main = state.primaryCamera;
    final second = _other(main);
    final filterSource = _filterTarget == 0 ? main : second;

    final left = [
      _FiltersPanel(
        source: filterSource,
        target: _filterTarget,
        onTarget: (t) => setState(() => _filterTarget = t),
      ),
      const _ArmPanel(),
      const HudPanel(title: 'Modos', icon: Icons.sports_esports_outlined, child: ModesCard()),
    ];
    // Movimiento arriba y Control (velocidad, motores) justo debajo.
    final right = const [_TelemetryPanel(), _MovementPanel(), _ControlPanel()];

    return LayoutBuilder(builder: (context, c) {
      final compact = c.maxWidth < 640 || c.maxHeight < 280;
      final gap = 8 * u;

      if (compact) {
        final panelW = c.maxWidth >= 720 ? (c.maxWidth - gap * 3) / 2 : c.maxWidth - gap * 2;
        return Column(
          children: [
            Expanded(
              child: ListView(
                padding: EdgeInsets.all(gap),
                children: [
                  AspectRatio(aspectRatio: 16 / 9, child: _CamView(source: main, index: 1, main: true, pip: second)),
                  SizedBox(height: gap),
                  if (state.controlLocked) ...[const _LockBanner(), SizedBox(height: gap)],
                  Wrap(
                    spacing: gap,
                    runSpacing: gap,
                    children: [for (final p in [...right, ...left]) SizedBox(width: panelW, child: p)],
                  ),
                ],
              ),
            ),
            const _BottomBar(),
          ],
        );
      }

      final leftW = (c.maxWidth * 0.2).clamp(176.0, 330.0);
      final rightW = (c.maxWidth * 0.215).clamp(186.0, 350.0);
      final centerH = c.maxHeight - 46 * u - gap * 2;
      final stacked = centerH >= 330 * u;

      Widget column(List<Widget> panels) => ListView.separated(
            padding: EdgeInsets.zero,
            itemCount: panels.length,
            separatorBuilder: (_, _) => SizedBox(height: gap),
            itemBuilder: (_, i) => panels[i],
          );

      return Column(
        children: [
          Expanded(
            child: Padding(
              padding: EdgeInsets.fromLTRB(gap, gap, gap, 0),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(width: leftW, child: column(stacked ? [left[2], left[1], left[0]] : [left[1], left[2], left[0]])),
                  SizedBox(width: gap),
                  Expanded(
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: stacked
                              ? Column(
                                  children: [
                                    Expanded(child: _CamView(source: main, index: 1, main: true)),
                                    SizedBox(height: gap),
                                    Expanded(child: _CamView(source: second, index: 2)),
                                  ],
                                )
                              : _CamView(source: main, index: 1, main: true, pip: second),
                        ),
                        if (state.controlLocked) Positioned(top: 34 * u, left: 14 * u, right: 14 * u, child: const _LockBanner()),
                      ],
                    ),
                  ),
                  SizedBox(width: gap),
                  SizedBox(width: rightW, child: column(stacked ? right : [right[1], right[2], right[0]])),
                ],
              ),
            ),
          ),
          SizedBox(height: gap),
          const _BottomBar(),
        ],
      );
    });
  }
}

// =============================================================
//  Cámaras
// =============================================================

class _CamView extends StatelessWidget {
  final AiCameraSource source;
  final int index;
  final bool main;
  final AiCameraSource? pip; // si no caben las dos: la otra va en miniatura
  const _CamView({required this.source, required this.index, this.main = false, this.pip});

  @override
  Widget build(BuildContext context) {
    final u = context.u;
    final state = context.watch<AppState>();
    context.watch<TapoCamService>(); // repinta el punto EN VIVO de CAM 2
    context.watch<DeviceConfig>();
    final live = CameraFeed.isLive(context, source);
    final media = context.watch<MediaLibrary>();
    final rec = media.isRecording(source) || media.isDualRecording;
    final paused = state.fullscreenOpen && source == AiCameraSource.esp32cam;

    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadius.lg),
      child: Container(
        decoration: BoxDecoration(border: Border.all(color: AppColors.line), borderRadius: BorderRadius.circular(AppRadius.lg)),
        child: LayoutBuilder(builder: (context, c) {
          final showCompass = main && pip == null && c.maxHeight > 210 * u && c.maxWidth > 380 * u;
          return Stack(
            fit: StackFit.expand,
            children: [
              CameraFeed(source: source, paused: paused || (pip != null && state.fullscreenOpen)),
              const ViewfinderOverlay(),
              Positioned(
                top: 10 * u,
                left: 12 * u,
                child: Row(
                  children: [
                    StatusDot(color: live ? AppColors.olive : AppColors.text3, size: 6),
                    SizedBox(width: 8 * u),
                    Text(cameraTitle(source), style: AppText.label.copyWith(color: AppColors.text1, fontSize: 10)),
                  ],
                ),
              ),
              Positioned(
                top: 10 * u,
                right: 12 * u,
                child: Row(
                  children: [
                    if (source == AiCameraSource.tapoCam)
                      const Cam2SourceSelector(compact: true)
                    else
                      Text('MJPEG', style: AppText.label.copyWith(fontSize: 9.5)),
                    if (rec) ...[
                      SizedBox(width: 12 * u),
                      const StatusDot(color: AppColors.red, size: 6),
                      SizedBox(width: 6 * u),
                      Text('REC', style: AppText.label.copyWith(color: AppColors.text1, fontSize: 9.5)),
                    ],
                  ],
                ),
              ),
              if (showCompass)
                Positioned(
                  right: 18 * u,
                  top: 30 * u,
                  child: HudCompass(heading: state.heading, size: (c.maxHeight * 0.42 / u).clamp(80, 130), caption: 'RUMBO EST.'),
                ),
              if (pip != null)
                Positioned(
                  right: 10 * u,
                  bottom: 10 * u,
                  width: (c.maxWidth * 0.3).clamp(110.0, 260.0),
                  child: AspectRatio(
                    aspectRatio: 16 / 10,
                    child: GestureDetector(
                      onTap: () => state.setPrimaryCamera(pip!),
                      child: Container(
                        decoration: BoxDecoration(border: Border.all(color: AppColors.text3), borderRadius: BorderRadius.circular(AppRadius.md)),
                        clipBehavior: Clip.antiAlias,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            CameraFeed(source: pip!, paused: state.fullscreenOpen),
                            Positioned(
                              top: 4 * u,
                              left: 6 * u,
                              child: Text(cameraTitle(pip!), style: AppText.label.copyWith(fontSize: 8, color: AppColors.text1)),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              Positioned(
                left: 10 * u,
                bottom: 10 * u,
                child: Row(
                  children: [
                    HudIconButton(
                      icon: Icons.fullscreen_rounded,
                      size: 32,
                      tooltip: 'Pantalla completa',
                      onTap: () => openCameraFullscreen(context, source),
                    ),
                    SizedBox(width: 6 * u),
                    HudIconButton(
                      icon: Icons.center_focus_weak_rounded,
                      size: 32,
                      tooltip: 'Analizar con IA',
                      onTap: () {
                        final assistant = context.read<AssistantState>();
                        if (assistant.isBusy) return;
                        state.setAiCameraSource(source);
                        assistant.analyzeCurrentFrame();
                        showAppToast(context, 'Analizando ${cameraTitle(source)}…');
                      },
                    ),
                    if (source == AiCameraSource.tapoCam) ...[
                      SizedBox(width: 6 * u),
                      Builder(builder: (context) {
                        final tapo = context.watch<TapoCamService>();
                        return HudIconButton(
                          icon: tapo.muted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
                          size: 32,
                          active: !tapo.muted,
                          tooltip: tapo.muted ? 'Activar sonido de CAM 2' : 'Silenciar CAM 2',
                          onTap: tapo.toggleMute,
                        );
                      }),
                    ],
                    if (main && pip == null) ...[
                      SizedBox(width: 6 * u),
                      HudIconButton(
                        icon: Icons.swap_vert_rounded,
                        size: 32,
                        tooltip: 'Intercambiar cámaras',
                        onTap: () => state.setPrimaryCamera(source == AiCameraSource.tapoCam ? AiCameraSource.esp32cam : AiCameraSource.tapoCam),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          );
        }),
      ),
    );
  }
}

class _LockBanner extends StatelessWidget {
  const _LockBanner();

  @override
  Widget build(BuildContext context) {
    final u = context.u;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 12 * u, vertical: 8 * u),
      decoration: BoxDecoration(
        color: AppColors.ink.withValues(alpha: 0.9),
        border: Border.all(color: AppColors.yellow.withValues(alpha: 0.6)),
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Row(
        children: [
          Icon(Icons.lock_outline_rounded, size: 16 * u, color: AppColors.yellow),
          SizedBox(width: 10 * u),
          Expanded(
            child: Text(
              'SISTEMA EN ESPERA — vincula los nodos y presiona INICIAR para habilitar el control.',
              style: AppText.label.copyWith(color: AppColors.text1, fontSize: 10),
            ),
          ),
          SizedBox(width: 10 * u),
          HudChip(
            text: 'Conexiones',
            icon: Icons.chevron_right_rounded,
            active: true,
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ConexionesScreen())),
          ),
        ],
      ),
    );
  }
}

// =============================================================
//  Columna izquierda
// =============================================================

class _FiltersPanel extends StatelessWidget {
  final AiCameraSource source;
  final int target;
  final ValueChanged<int> onTarget;
  const _FiltersPanel({required this.source, required this.target, required this.onTarget});

  @override
  Widget build(BuildContext context) {
    final u = context.u;
    final state = context.watch<AppState>();
    final current = state.filterOf(source);
    Widget targetBtn(int t) => GestureDetector(
          onTap: () => onTarget(t),
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: 6 * u, vertical: 2 * u),
            decoration: BoxDecoration(
              color: target == t ? AppColors.militaryDark : null,
              border: Border.all(color: target == t ? AppColors.military : AppColors.line),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text('0${t + 1}', style: AppText.label.copyWith(fontSize: 9, color: target == t ? AppColors.text1 : AppColors.text2)),
          ),
        );

    return HudPanel(
      title: 'Filtros',
      icon: Icons.filter_alt_outlined,
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [targetBtn(0), SizedBox(width: 4 * u), targetBtn(1)]),
      padding: EdgeInsets.fromLTRB(12 * u, 10 * u, 12 * u, 6 * u),
      child: Column(
        children: [
          for (final m in CameraFilterMode.values)
            InkWell(
              onTap: () => state.setFilter(source, m),
              child: Container(
                padding: EdgeInsets.symmetric(vertical: 7 * u),
                decoration: const BoxDecoration(border: Border(top: BorderSide(color: AppColors.lineSoft))),
                child: Row(
                  children: [
                    Container(
                      width: 12 * u,
                      height: 12 * u,
                      decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: m == current ? AppColors.text1 : AppColors.text3)),
                      alignment: Alignment.center,
                      child: m == current ? Container(width: 6 * u, height: 6 * u, decoration: const BoxDecoration(color: AppColors.text1, shape: BoxShape.circle)) : null,
                    ),
                    SizedBox(width: 10 * u),
                    Icon(m.icon, size: 14 * u, color: m == current ? AppColors.text1 : AppColors.text2),
                    SizedBox(width: 8 * u),
                    Expanded(
                      child: Text(m.label, style: TextStyle(fontSize: 11.5, color: m == current ? AppColors.text1 : AppColors.text2), overflow: TextOverflow.ellipsis),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ArmPanel extends StatelessWidget {
  const _ArmPanel();

  @override
  Widget build(BuildContext context) {
    final u = context.u;
    final state = context.watch<AppState>();
    const step = 8;
    final locked = state.controlLocked;

    return HudPanel(
      title: 'Brazo 2 ejes',
      icon: Icons.precision_manufacturing_outlined,
      child: Opacity(
        opacity: locked ? 0.4 : 1,
        child: IgnorePointer(
          ignoring: locked,
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Flexible(
                    child: FittedBox(
                      child: ArmJoystick(size: 104, pan: state.armPan, tilt: state.armTilt, onChanged: state.setArmAngles),
                    ),
                  ),
                  SizedBox(width: 8 * u),
                  Container(
                    padding: EdgeInsets.all(5 * u),
                    decoration: BoxDecoration(border: Border.all(color: AppColors.line), borderRadius: BorderRadius.circular(AppRadius.md)),
                    child: Column(
                      children: [
                        Text('TILT', style: AppText.label.copyWith(fontSize: 8.5)),
                        SizedBox(height: 4 * u),
                        HudIconButton(icon: Icons.arrow_upward_rounded, size: 30, onTap: () => state.nudgeArm(tilt: step)),
                        SizedBox(height: 5 * u),
                        HudIconButton(icon: Icons.arrow_downward_rounded, size: 30, onTap: () => state.nudgeArm(tilt: -step)),
                      ],
                    ),
                  ),
                ],
              ),
              SizedBox(height: 8 * u),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'PAN  ${(state.armPan * 1.8).round()}°\nTILT ${(state.armTilt * 1.8).round()}°',
                      style: AppText.label.copyWith(fontSize: 8.5, color: AppColors.text1),
                    ),
                  ),
                  HudIconButton(icon: Icons.chevron_left_rounded, size: 30, onTap: () => state.nudgeArm(pan: -step)),
                  SizedBox(width: 6 * u),
                  HudIconButton(icon: Icons.chevron_right_rounded, size: 30, onTap: () => state.nudgeArm(pan: step)),
                  SizedBox(width: 6 * u),
                  HudIconButton(icon: Icons.center_focus_strong_outlined, size: 30, tooltip: 'Ir a la posición 0', onTap: state.centerArm),
                  SizedBox(width: 6 * u),
                  HudIconButton(
                    icon: Icons.push_pin_outlined,
                    size: 30,
                    active: state.armPan == state.armHomePan && state.armTilt == state.armHomeTilt,
                    tooltip: 'Fijar posición 0 aquí (mantener = volver a 90°/90°)',
                    onTap: () {
                      state.setArmHome();
                      showAppToast(context, 'Posición 0 del brazo: PAN ${(state.armPan * 1.8).round()}° · TILT ${(state.armTilt * 1.8).round()}°');
                    },
                    onLongPress: () {
                      state.resetArmHome();
                      showAppToast(context, 'Posición 0 de fábrica (90° / 90°)');
                    },
                  ),
                ],
              ),
              SizedBox(height: 8 * u),
              Row(
                children: [
                  for (var i = 0; i < 3; i++) ...[
                    if (i > 0) SizedBox(width: 6 * u),
                    Expanded(child: _PresetSlot(index: i)),
                  ],
                ],
              ),
              SizedBox(height: 4 * u),
              Text('vacío = guardar · lleno = ir · mantener = regrabar · 📌 = fijar posición 0', style: AppText.label.copyWith(fontSize: 7.5, color: AppColors.text3)),
            ],
          ),
        ),
      ),
    );
  }
}

class _PresetSlot extends StatelessWidget {
  final int index;
  const _PresetSlot({required this.index});

  @override
  Widget build(BuildContext context) {
    final u = context.u;
    final state = context.watch<AppState>();
    final label = const ['A', 'B', 'C'][index];
    final filled = state.armPresets[index] != null;
    return Material(
      color: filled ? AppColors.militaryDark.withValues(alpha: 0.6) : AppColors.ink.withValues(alpha: 0.5),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.sm),
        side: BorderSide(color: filled ? AppColors.military : AppColors.line),
      ),
      child: InkWell(
        onTap: () {
          if (filled) {
            state.recallArmPreset(index);
            showAppToast(context, 'Brazo a posición $label');
          } else {
            state.saveArmPreset(index);
            showAppToast(context, 'Posición $label guardada');
          }
        },
        onLongPress: () {
          if (filled) {
            state.clearArmPreset(index);
            showAppToast(context, 'Posición $label borrada');
          } else {
            state.saveArmPreset(index);
            showAppToast(context, 'Posición $label guardada');
          }
        },
        child: SizedBox(
          height: 28 * u,
          child: Center(child: Text(label, style: AppText.value.copyWith(fontSize: 12, color: filled ? AppColors.text1 : AppColors.text3))),
        ),
      ),
    );
  }
}

// =============================================================
//  Columna derecha
// =============================================================

class _TelemetryPanel extends StatelessWidget {
  const _TelemetryPanel();

  @override
  Widget build(BuildContext context) {
    final u = context.u;
    final state = context.watch<AppState>();
    final link = context.watch<BotLink>();
    final config = context.watch<DeviceConfig>();
    final sensorsOnline = config.of(HardwareNode.esp32Sensors).isOnline;
    final gas = state.gasReadings['mq2']!;
    final gasAlert = gas.isWarn;
    final ping = link.rttMs ?? config.of(HardwareNode.esp32s3Control).latencyMs;

    Widget row(String label, String value, Widget side, {Color? color}) => Padding(
          padding: EdgeInsets.symmetric(vertical: 5 * u),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: AppText.label.copyWith(fontSize: 8.5)),
                    SizedBox(height: 2 * u),
                    Text(value, style: AppText.value.copyWith(fontSize: 14, color: color)),
                  ],
                ),
              ),
              SizedBox(width: 72 * u, child: side),
            ],
          ),
        );

    return HudPanel(
      title: 'Telemetría',
      icon: Icons.monitor_heart_outlined,
      trailing: sensorsOnline ? null : Text('DEMO', style: AppText.label.copyWith(fontSize: 8.5, color: AppColors.yellow)),
      child: Column(
        children: [
          row(
            gasAlert ? 'GAS · MQ-2 · ALERTA' : 'GAS · MQ-2 · NORMAL',
            '${gas.value.toStringAsFixed(0).padLeft(3, '0')} %',
            Sparkline(values: state.gasHistory),
            color: gasAlert ? AppColors.red : null,
          ),
          row('PING · CONTROL', ping == null ? '— ms' : '$ping ms', Sparkline(values: link.rttHistory)),
          row('RSSI', link.estado?.rssi == null ? '— dBm' : '${link.estado!.rssi} dBm',
              Align(alignment: Alignment.centerRight, child: SignalBars(rssi: link.estado?.rssi))),
        ],
      ),
    );
  }
}

class _ControlPanel extends StatelessWidget {
  const _ControlPanel();

  @override
  Widget build(BuildContext context) {
    final u = context.u;
    final state = context.watch<AppState>();
    final link = context.watch<BotLink>();
    final l = (link.estado?.l ?? 0).abs() / 255;
    final r = (link.estado?.r ?? 0).abs() / 255;

    Widget motor(String name, double v, int raw) => Padding(
          padding: EdgeInsets.only(top: 6 * u),
          child: Row(
            children: [
              SizedBox(width: 30 * u, child: Text(name, style: AppText.label.copyWith(fontSize: 9))),
              SizedBox(
                width: 46 * u,
                child: Text('${raw < 0 ? '-' : ''}${(v * 100).round()}%', style: AppText.value.copyWith(fontSize: 11)),
              ),
              Expanded(child: BarMeter(value: v, color: raw < 0 ? AppColors.yellow : AppColors.text2)),
            ],
          ),
        );

    return HudPanel(
      title: 'Control',
      icon: Icons.tune_rounded,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text('VELOCIDAD (THROTTLE)', style: AppText.label.copyWith(fontSize: 8.5)),
              const Spacer(),
              Text('${state.speed}%', style: AppText.value.copyWith(fontSize: 13)),
            ],
          ),
          SizedBox(
            height: 28 * u,
            child: IgnorePointer(
              ignoring: state.controlLocked,
              child: Slider(value: state.speed.toDouble(), min: 0, max: 100, onChanged: (v) => state.setSpeed(v.round())),
            ),
          ),
          Text('MOTORES', style: AppText.label.copyWith(fontSize: 8.5)),
          motor('IZQ', l, link.estado?.l ?? 0),
          motor('DER', r, link.estado?.r ?? 0),
        ],
      ),
    );
  }
}

class _MovementPanel extends StatelessWidget {
  const _MovementPanel();

  @override
  Widget build(BuildContext context) {
    final u = context.u;
    final state = context.watch<AppState>();
    final locked = state.controlLocked;
    return HudPanel(
      title: 'Movimiento',
      icon: Icons.open_with_rounded,
      child: Opacity(
        opacity: locked ? 0.4 : 1,
        child: IgnorePointer(
          ignoring: locked,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              // Cruceta de 4 flechas: mantener presionada = avanza; soltar = frena.
              Flexible(
                child: FittedBox(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const _HoldArrow(icon: Icons.keyboard_arrow_up_rounded, move: 'adelante', tooltip: 'Adelante'),
                      SizedBox(height: 4 * u),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const _HoldArrow(icon: Icons.keyboard_arrow_left_rounded, move: 'giro-izq', tooltip: 'Izquierda'),
                          SizedBox(width: 4 * u),
                          HudIconButton(icon: Icons.stop_rounded, size: 44, tooltip: 'Detener', onTap: () => state.pressMove('detener')),
                          SizedBox(width: 4 * u),
                          const _HoldArrow(icon: Icons.keyboard_arrow_right_rounded, move: 'giro-der', tooltip: 'Derecha'),
                        ],
                      ),
                      SizedBox(height: 4 * u),
                      const _HoldArrow(icon: Icons.keyboard_arrow_down_rounded, move: 'atras', tooltip: 'Atrás'),
                    ],
                  ),
                ),
              ),
              SizedBox(width: 8 * u),
              Column(
                children: [
                  const _HoldArrow(icon: Icons.turn_slight_left_rounded, move: 'izquierda', size: 34, tooltip: 'Curva a la izquierda (avanzando)'),
                  SizedBox(height: 6 * u),
                  const _HoldArrow(icon: Icons.turn_slight_right_rounded, move: 'derecha', size: 34, tooltip: 'Curva a la derecha (avanzando)'),
                  SizedBox(height: 6 * u),
                  const _SpinButton(),
                  SizedBox(height: 6 * u),
                  HudIconButton(
                    icon: Icons.error_outline_rounded,
                    size: 34,
                    danger: true,
                    tooltip: 'Paro de emergencia',
                    onTap: () {
                      state.emergencyStop();
                      final link = context.read<BotLink>();
                      if (link.playing != null || link.starting != null) link.stopFromApp();
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// GIRO 360°: una vuelta completa sobre su eje (toque = a la derecha,
/// mantener = a la izquierda; otra vez = cancelar). Mismo giro que 2x R2 en
/// el mando. Usa los segundos por vuelta de Sistema › Exploración autónoma.
class _SpinButton extends StatelessWidget {
  const _SpinButton();

  @override
  Widget build(BuildContext context) {
    final route = context.watch<AutoRoute>();
    Future<void> spin(bool left) async {
      final msg = await route.spin360(left: left);
      if (context.mounted) showAppToast(context, msg);
    }

    return HudIconButton(
      icon: Icons.threesixty_rounded,
      size: 34,
      active: route.spinning,
      tooltip: 'Girar 360° sobre su eje (mantener = a la izquierda)',
      onTap: () => spin(false),
      onLongPress: () => spin(true),
    );
  }
}

/// Flecha de manejo: mientras el dedo esté encima el carrito se mueve
/// (AppState.holdMove repite el comando cada 300 ms); al soltar, frena.
class _HoldArrow extends StatelessWidget {
  final IconData icon;
  final String move;
  final double size;
  final String tooltip;
  const _HoldArrow({required this.icon, required this.move, this.size = 44, required this.tooltip});

  @override
  Widget build(BuildContext context) {
    final u = context.u;
    final state = context.watch<AppState>();
    final active = state.pressedMove == move;
    final s = size * u;
    return Tooltip(
      message: tooltip,
      child: Listener(
        onPointerDown: (_) => state.holdMove(move),
        onPointerUp: (_) => state.releaseMove(),
        onPointerCancel: (_) => state.releaseMove(),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 90),
          width: s,
          height: s,
          decoration: BoxDecoration(
            color: active ? AppColors.militaryDark.withValues(alpha: 0.9) : AppColors.ink.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(color: active ? AppColors.military : AppColors.line, width: active ? 1.6 : 1),
          ),
          child: Icon(icon, size: s * 0.62, color: active ? AppColors.text1 : AppColors.text2),
        ),
      ),
    );
  }
}

// =============================================================
//  Barra inferior
// =============================================================

class _BottomBar extends StatelessWidget {
  const _BottomBar();

  @override
  Widget build(BuildContext context) {
    final u = context.u;
    final state = context.watch<AppState>();
    final assistant = context.watch<AssistantState>();
    final controlOnline = context.watch<DeviceConfig>().of(HardwareNode.esp32s3Control).isOnline;

    final (aLabel, aColor) = switch (assistant.status) {
      AssistantStatus.listening => (assistant.transcript.isEmpty ? 'ESCUCHANDO…' : '"${assistant.transcript}"', AppColors.olive),
      AssistantStatus.processing => ('PROCESANDO…', AppColors.yellow),
      AssistantStatus.speaking => (assistant.lastResponse.isEmpty ? 'HABLANDO…' : assistant.lastResponse, AppColors.text1),
      AssistantStatus.error => (assistant.errorMessage ?? 'Error', AppColors.red),
      AssistantStatus.idle => (assistant.lastResponse.isNotEmpty ? assistant.lastResponse : 'Asistente de voz: toca el micrófono', AppColors.text2),
    };

    return LayoutBuilder(builder: (context, c) {
      final wide = c.maxWidth > 820;
      Widget sep() => Container(width: 1, height: 22 * u, margin: EdgeInsets.symmetric(horizontal: 10 * u), color: AppColors.line);
      Widget action(IconData icon, String label, VoidCallback? onTap, {bool busy = false}) => InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(AppRadius.md),
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 6 * u, vertical: 4 * u),
              child: Row(
                children: [
                  Container(
                    width: 30 * u,
                    height: 30 * u,
                    decoration: BoxDecoration(border: Border.all(color: AppColors.line), borderRadius: BorderRadius.circular(AppRadius.md)),
                    child: busy
                        ? Padding(padding: EdgeInsets.all(8 * u), child: const CircularProgressIndicator(strokeWidth: 1.5))
                        : Icon(icon, size: 16 * u, color: AppColors.text1),
                  ),
                  if (wide) ...[SizedBox(width: 8 * u), Text(label, style: AppText.label.copyWith(color: AppColors.text1, fontSize: 9.5))],
                ],
              ),
            ),
          );

      return Container(
        height: 46 * u,
        padding: EdgeInsets.symmetric(horizontal: 8 * u),
        decoration: const BoxDecoration(
          color: AppColors.ink,
          border: Border(top: BorderSide(color: AppColors.lineSoft)),
        ),
        child: Row(
          children: [
            action(Icons.photo_camera_outlined, 'CAPTURA', state.capturingPhoto
                ? null
                : () async {
                    final msg = await state.takePhoto();
                    if (context.mounted) showAppToast(context, msg);
                  }, busy: state.capturingPhoto),
            sep(),
            Builder(builder: (context) {
              context.watch<MediaLibrary>();
              final recording = state.videoRecording;
              return action(
                recording ? Icons.stop_circle_outlined : Icons.fiber_manual_record_outlined,
                recording ? 'DETENER\n${formatDuration(state.videoElapsed)}' : (state.recordBoth ? 'GRABAR\nCAM 1+2' : 'GRABAR\nVIDEO'),
                state.videoToggling
                    ? null
                    : () async {
                        final msg = await state.toggleRecording();
                        if (context.mounted) showAppToast(context, msg);
                      },
              );
            }),
            // 1 CAM / 2 CAM: qué graba el botón GRABAR (y el mando).
            Tooltip(
              message: state.recordBoth ? 'Graba las 2 cámaras en un solo video' : 'Graba solo la cámara principal',
              child: InkWell(
                onTap: state.videoRecording ? null : () => state.setRecordBoth(!state.recordBoth),
                borderRadius: BorderRadius.circular(AppRadius.sm),
                child: Container(
                  padding: EdgeInsets.symmetric(horizontal: 6 * u, vertical: 3 * u),
                  decoration: BoxDecoration(
                    color: state.recordBoth ? AppColors.militaryDark : null,
                    border: Border.all(color: state.recordBoth ? AppColors.military : AppColors.line),
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                  ),
                  child: Text(state.recordBoth ? '2 CAM' : '1 CAM', style: AppText.label.copyWith(fontSize: 8.5, color: state.recordBoth ? AppColors.text1 : AppColors.text2)),
                ),
              ),
            ),
            sep(),
            action(Icons.desktop_windows_outlined, 'PANTALLA\nCOMPLETA', () => openCameraFullscreen(context, state.primaryCamera)),
            sep(),
            Flexible(
              flex: 2,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(controlOnline ? 'ESTADO' : 'ESTADO · DEMO', style: AppText.label.copyWith(fontSize: 8, color: controlOnline ? AppColors.text3 : AppColors.yellow)),
                  Text(state.stateValue.toUpperCase(), style: AppText.label.copyWith(color: AppColors.text1, fontSize: 9.5), overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
            sep(),
            HudIconButton(
              icon: assistant.status == AssistantStatus.listening ? Icons.mic_rounded : Icons.mic_none_rounded,
              size: 32,
              round: true,
              active: assistant.status == AssistantStatus.listening,
              tooltip: 'Asistente de voz',
              onTap: assistant.isBusy ? null : assistant.toggleMic,
            ),
            SizedBox(width: 8 * u),
            Expanded(
              flex: 3,
              child: GestureDetector(
                onTap: assistant.lastResponse.isEmpty
                    ? null
                    : () => showDialog(
                          context: context,
                          builder: (_) => AlertDialog(
                            title: Text('ASISTENTE', style: AppText.sectionTitle),
                            content: SingleChildScrollView(child: Text(assistant.lastResponse, style: const TextStyle(fontSize: 13, height: 1.4))),
                            actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('CERRAR'))],
                          ),
                        ),
                child: Text(aLabel, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 10.5, color: aColor, height: 1.25)),
              ),
            ),
            IconButton(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const VoiceCommandsHelpScreen())),
              icon: Icon(Icons.help_outline_rounded, size: 17 * u, color: AppColors.text3),
              tooltip: 'Comandos de voz',
              visualDensity: VisualDensity.compact,
            ),
            IconButton(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => GeminiLogScreen(geminiService: assistant.geminiService))),
              icon: Icon(Icons.receipt_long_outlined, size: 17 * u, color: AppColors.text3),
              tooltip: 'Log de Gemini',
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
      );
    });
  }
}
