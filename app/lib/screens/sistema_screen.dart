import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_theme.dart';
import '../state/app_state.dart';
import '../state/bot_link.dart';
import '../widgets/common.dart';
import '../widgets/top_bar.dart';
import 'autonomo_settings_screen.dart';
import 'conexiones_screen.dart';
import 'gemini_settings_screen.dart';
import 'motor_calibration_screen.dart';
import 'vision_settings_screen.dart';
import 'voice_commands_help_screen.dart';

/// Abre el perfil de TikTok en la app de TikTok si está instalada, o en el
/// navegador si no. Si por lo que sea no se puede abrir nada, avisa con un
/// toast en vez de fallar en silencio.
Future<void> _openTikTok(BuildContext context) async {
  final uri = Uri.parse('https://www.tiktok.com/@gabbgari');
  final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
  if (!ok && context.mounted) {
    showAppToast(context, 'No se pudo abrir TikTok');
  }
}

class SistemaScreen extends StatelessWidget {
  const SistemaScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final link = context.watch<BotLink>();

    return Column(
      children: [
        ScreenTopBar(title: 'Sistema', onBack: () => state.showScreen(ScreenNames.inicio)),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
            children: [
              AppCard(
                padding: EdgeInsets.zero,
                child: Column(
                  children: [
                    _SettingsItem(
                      icon: Icons.wifi_rounded,
                      title: 'Conexiones',
                      subtitle: 'Vincular ESP32-CAM / ESP32-S3 / ESP32',
                      highlight: true,
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const ConexionesScreen()),
                      ),
                    ),
                    _SettingsItem(
                      icon: Icons.auto_awesome_rounded,
                      title: 'Asistente IA',
                      subtitle: 'API Key de Gemini · voz y visión',
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const GeminiSettingsScreen()),
                      ),
                    ),
                    _SettingsItem(
                      icon: Icons.local_fire_department_outlined,
                      title: 'Visión IA (YOLO)',
                      subtitle: 'IP de la PC de visión · fuente de CAM 2 · alerta de fuego',
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const VisionSettingsScreen()),
                      ),
                    ),
                    _SettingsItem(
                      icon: Icons.tune_rounded,
                      title: 'Calibración de motores',
                      subtitle: 'Fuerza de cada BTS7960 (izquierdo / derecho)',
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const MotorCalibrationScreen()),
                      ),
                    ),
                    _SettingsItem(
                      icon: Icons.smart_toy_outlined,
                      title: 'Exploración autónoma',
                      subtitle: 'Segundos por vuelta · regreso inteligente · base del brazo',
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const AutonomoSettingsScreen()),
                      ),
                    ),
                    _SettingsItem(
                      icon: Icons.record_voice_over_rounded,
                      title: 'Comandos de voz',
                      subtitle: 'Glosario: qué puedes decir y qué hace',
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const VoiceCommandsHelpScreen()),
                      ),
                    ),
                    _SettingsItem(
                      icon: Icons.info_outline_rounded,
                      title: 'Información del dispositivo',
                      subtitle: 'Hardware / Firmware / Versión',
                      onTap: () => showAppToast(context, 'SHADOWBOT v2.0 · by GABGARI'),
                    ),
                    _SettingsItem(
                      icon: Icons.smart_display_rounded,
                      title: 'Síguenos en TikTok',
                      subtitle: '@gabbgari',
                      last: true,
                      onTap: () => _openTikTok(context),
                    ),
                  ],
                ),
              ),
              const SectionTitle('Estado de CONTROL'),
              Row(
                children: [
                  Expanded(child: _StatCard(label: 'Ping', value: link.rttMs == null ? '—' : '${link.rttMs} ms')),
                  const SizedBox(width: 10),
                  Expanded(child: _StatCard(label: 'Señal WiFi', value: link.estado?.rssi == null ? '—' : '${link.estado!.rssi} dBm')),
                  const SizedBox(width: 10),
                  Expanded(child: _StatCard(label: 'Modo', value: BotLink.modeLabel(link.botMode))),
                ],
              ),
              const SizedBox(height: 18),
              GhostButton(label: 'Ver alertas y eventos', onPressed: () => state.showScreen(ScreenNames.alertas)),
            ],
          ),
        ),
      ],
    );
  }
}

class _SettingsItem extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool highlight;
  final bool last;

  const _SettingsItem({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.highlight = false,
    this.last = false,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 13, horizontal: 2),
        decoration: BoxDecoration(
          border: last ? null : const Border(bottom: BorderSide(color: AppColors.lineSoft)),
        ),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: AppColors.surface2,
                border: Border.all(color: AppColors.lineSoft),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, size: 17, color: highlight ? AppColors.orange : AppColors.text1),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.text1)),
                  Text(subtitle, style: const TextStyle(fontSize: 11, color: AppColors.text2)),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded, size: 18, color: AppColors.text3),
          ],
        ),
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  final String label;
  final String value;
  const _StatCard({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 11, color: AppColors.text2, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          FittedBox(child: Text(value, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: AppColors.text1))),
        ],
      ),
    );
  }
}
