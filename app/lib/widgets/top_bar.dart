import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_theme.dart';
import '../models/node_link.dart';
import '../services/device_config.dart';
import '../state/app_state.dart';
import '../state/bot_link.dart';
import '../state/gamepad_link.dart';
import 'hud.dart';

/// Secciones del menú lateral (el "/ NAVEGACIÓN" de la barra superior).
class HudSection {
  final String screen;
  final IconData icon;
  final String label;
  const HudSection(this.screen, this.icon, this.label);
}

const hudSections = [
  HudSection(ScreenNames.control, Icons.explore_outlined, 'Navegación'),
  HudSection(ScreenNames.camara, Icons.videocam_outlined, 'Cámaras'),
  HudSection(ScreenNames.sensores, Icons.sensors_outlined, 'Sensores'),
  HudSection(ScreenNames.galeria, Icons.perm_media_outlined, 'Multimedia'),
  HudSection(ScreenNames.nodos, Icons.hub_outlined, 'Nodos'),
  HudSection(ScreenNames.mando, Icons.sports_esports_outlined, 'Mando'),
  HudSection(ScreenNames.alertas, Icons.warning_amber_rounded, 'Alertas'),
  HudSection(ScreenNames.sistema, Icons.settings_outlined, 'Sistema'),
];

String sectionLabel(String screen) {
  for (final s in hudSections) {
    if (s.screen == screen) return s.label;
  }
  return 'Navegación';
}

/// Barra superior de toda la app: "SHADOW BOT / SECCIÓN" a la izquierda y
/// el estado del enlace a la derecha (en línea, ping, RSSI, modo, hora).
class HudTopBar extends StatelessWidget {
  final String section;
  final VoidCallback onMenu;
  final VoidCallback? onSettings;
  final Widget? trailing;
  const HudTopBar({super.key, required this.section, required this.onMenu, this.onSettings, this.trailing});

  @override
  Widget build(BuildContext context) {
    final u = context.u;
    final config = context.watch<DeviceConfig>();
    final link = context.watch<BotLink>();
    final control = config.of(HardwareNode.esp32s3Control);
    final online = link.estado != null || control.isOnline;
    final ping = link.rttMs ?? control.latencyMs;
    final rssi = link.estado?.rssi;
    final pad = context.select<GamepadLink, bool>((g) => g.connected);

    return LayoutBuilder(builder: (context, c) {
      final w = c.maxWidth;
      final showRssi = w > 760;
      final showPing = w > 620;
      final showClock = w > 520;
      Widget sep() => Container(width: 1, height: 14 * u, margin: EdgeInsets.symmetric(horizontal: 12 * u), color: AppColors.line);

      return Container(
        height: 40 * u,
        padding: EdgeInsets.symmetric(horizontal: 10 * u),
        decoration: const BoxDecoration(
          color: AppColors.ink,
          border: Border(bottom: BorderSide(color: AppColors.lineSoft)),
        ),
        child: Row(
          children: [
            InkWell(
              onTap: onMenu,
              borderRadius: BorderRadius.circular(AppRadius.md),
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 4 * u, vertical: 4 * u),
                child: Row(
                  children: [
                    Icon(Icons.hub_outlined, size: 18 * u, color: AppColors.text2),
                    SizedBox(width: 10 * u),
                    Text('SHADOW BOT', style: AppText.topbarTitle.copyWith(fontSize: 13)),
                    Text('  /  ', style: AppText.topbarTitle.copyWith(fontSize: 13, color: AppColors.text3)),
                    Text(section.toUpperCase(), style: AppText.topbarTitle.copyWith(fontSize: 13, color: AppColors.text2)),
                    SizedBox(width: 4 * u),
                    Icon(Icons.expand_more_rounded, size: 16 * u, color: AppColors.text3),
                  ],
                ),
              ),
            ),
            const Spacer(),
            StatusDot(color: online ? AppColors.olive : AppColors.text3, size: 6),
            SizedBox(width: 8 * u),
            Text(online ? 'EN LÍNEA' : 'SIN ENLACE', style: AppText.label.copyWith(color: AppColors.text1, fontSize: 10)),
            if (showPing) ...[
              sep(),
              Icon(Icons.speed_rounded, size: 13 * u, color: AppColors.text2),
              SizedBox(width: 6 * u),
              Text('PING ${ping ?? '—'} ms', style: AppText.label.copyWith(color: AppColors.text1, fontSize: 10)),
            ],
            if (showRssi) ...[
              sep(),
              Icon(Icons.wifi_rounded, size: 13 * u, color: AppColors.text2),
              SizedBox(width: 6 * u),
              Text('RSSI ${rssi ?? '—'} dBm', style: AppText.label.copyWith(color: AppColors.text1, fontSize: 10)),
            ],
            sep(),
            Text('MODO ', style: AppText.label.copyWith(fontSize: 10)),
            Text(BotLink.modeLabel(link.botMode), style: AppText.label.copyWith(color: link.botMode == 'juego' ? AppColors.olive : AppColors.text1, fontSize: 10)),
            if (pad) ...[
              sep(),
              Tooltip(message: 'Mando conectado al teléfono', child: Icon(Icons.sports_esports_rounded, size: 16 * u, color: AppColors.olive)),
            ],
            if (showClock) ...[sep(), HudClock(style: AppText.value.copyWith(fontSize: 12))],
            if (trailing != null) ...[SizedBox(width: 10 * u), trailing!],
            if (onSettings != null) ...[
              SizedBox(width: 6 * u),
              IconButton(
                onPressed: onSettings,
                icon: Icon(Icons.settings_outlined, size: 18 * u, color: AppColors.text2),
                visualDensity: VisualDensity.compact,
                tooltip: 'Sistema',
              ),
            ],
          ],
        ),
      );
    });
  }
}

/// Menú lateral con las secciones de la app.
class HudDrawer extends StatelessWidget {
  const HudDrawer({super.key});

  @override
  Widget build(BuildContext context) {
    final u = context.u;
    final state = context.watch<AppState>();
    return Drawer(
      width: 260 * u,
      shape: const RoundedRectangleBorder(),
      backgroundColor: AppColors.ink,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(18 * u, 18 * u, 18 * u, 10 * u),
              child: Row(
                children: [
                  ShadowLogo(size: 46 * u),
                  SizedBox(width: 12 * u),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('SHADOW BOT', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15, letterSpacing: 3, color: AppColors.text1)),
                        const SizedBox(height: 2),
                        Text('OPERATIONS', style: AppText.label.copyWith(fontSize: 9)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const Divider(color: AppColors.lineSoft, height: 1),
            Expanded(
              child: ListView(
                padding: EdgeInsets.symmetric(vertical: 8 * u),
                children: [
                  for (final s in hudSections)
                    _DrawerItem(
                      section: s,
                      active: state.currentScreen == s.screen,
                      onTap: () {
                        Navigator.of(context).pop();
                        state.showScreen(s.screen);
                      },
                    ),
                ],
              ),
            ),
            const Divider(color: AppColors.lineSoft, height: 1),
            Padding(
              padding: EdgeInsets.all(16 * u),
              child: Row(
                children: [
                  StatusDot(color: state.systemStarted ? AppColors.olive : AppColors.yellow, size: 6),
                  SizedBox(width: 8 * u),
                  Text(state.systemStarted ? 'SISTEMA ACTIVO' : 'SISTEMA EN ESPERA', style: AppText.label.copyWith(color: AppColors.text1)),
                  const Spacer(),
                  Text('BY GABGARI', style: AppText.label.copyWith(fontSize: 8.5, color: AppColors.text3)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DrawerItem extends StatelessWidget {
  final HudSection section;
  final bool active;
  final VoidCallback onTap;
  const _DrawerItem({required this.section, required this.active, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final u = context.u;
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 18 * u, vertical: 12 * u),
        decoration: BoxDecoration(
          color: active ? AppColors.militaryDark.withValues(alpha: 0.35) : null,
          border: Border(left: BorderSide(color: active ? AppColors.olive : Colors.transparent, width: 2)),
        ),
        child: Row(
          children: [
            Icon(section.icon, size: 18 * u, color: active ? AppColors.olive : AppColors.text2),
            SizedBox(width: 14 * u),
            Text(section.label.toUpperCase(), style: AppText.label.copyWith(fontSize: 11, color: active ? AppColors.text1 : AppColors.text2)),
          ],
        ),
      ),
    );
  }
}

/// Encabezado de cada pantalla secundaria: delgado, mono, con regreso
/// opcional y un estado a la derecha.
class ScreenTopBar extends StatelessWidget {
  final String title;
  final VoidCallback? onBack;
  final bool online;
  final String? statusLabel;

  const ScreenTopBar({
    super.key,
    required this.title,
    this.onBack,
    this.online = true,
    this.statusLabel,
  });

  @override
  Widget build(BuildContext context) {
    final u = context.u;
    return Padding(
      padding: EdgeInsets.fromLTRB(16 * u, 10 * u, 16 * u, 8 * u),
      child: Row(
        children: [
          if (onBack != null) ...[
            HudIconButton(icon: Icons.chevron_left_rounded, onTap: onBack, size: 32),
            SizedBox(width: 12 * u),
          ],
          Expanded(
            child: Text(title.toUpperCase(), style: AppText.topbarTitle, overflow: TextOverflow.ellipsis),
          ),
          if (statusLabel != null) ...[
            StatusDot(color: online ? AppColors.olive : AppColors.text3, size: 6),
            SizedBox(width: 8 * u),
            Text(statusLabel!.toUpperCase(), style: AppText.label.copyWith(fontSize: 10)),
          ],
        ],
      ),
    );
  }
}
