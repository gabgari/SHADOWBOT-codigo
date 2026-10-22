import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_theme.dart';
import '../models/node_link.dart';
import '../services/device_config.dart';
import '../state/app_state.dart';
import '../widgets/common.dart';
import '../widgets/top_bar.dart';
import 'node_detail_screen.dart';

class NodosScreen extends StatelessWidget {
  const NodosScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    final config = context.watch<DeviceConfig>();

    return Column(
      children: [
        ScreenTopBar(
          title: 'Nodos del sistema',
          onBack: () => state.showScreen(ScreenNames.inicio),
          statusLabel: config.anyOnline ? 'Algunos en línea' : 'Sin vincular',
          online: config.anyOnline,
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 18),
            children: [
              const Text(
                'Arquitectura de comunicación',
                style: TextStyle(fontSize: 12.5, color: AppColors.text2, fontWeight: FontWeight.w500),
              ),
              const SizedBox(height: 10),
              const _TopologyDiagram(),
              const SectionTitle('Estado de los nodos'),
              Text(
                'Toca un nodo para ver su estado y latencia real (ping en vivo).',
                style: const TextStyle(fontSize: 11.5, color: AppColors.text3),
              ),
              const SizedBox(height: 10),
              _NodeItem(
                icon: Icons.hub_rounded,
                title: 'ESP32-S3',
                role: 'Coordinador / Comunicación',
                link: config.of(HardwareNode.esp32s3Control),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const NodeDetailScreen(node: HardwareNode.esp32s3Control, icon: Icons.hub_rounded),
                )),
              ),
              const SizedBox(height: 8),
              _NodeItem(
                icon: Icons.videocam_rounded,
                title: 'ESP32-CAM',
                role: 'Video',
                link: config.of(HardwareNode.esp32cam),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const NodeDetailScreen(node: HardwareNode.esp32cam, icon: Icons.videocam_rounded),
                )),
              ),
              const SizedBox(height: 8),
              _NodeItem(
                icon: Icons.sensors_rounded,
                title: 'ESP32',
                role: 'Sensores + LEDs',
                link: config.of(HardwareNode.esp32Sensors),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const NodeDetailScreen(node: HardwareNode.esp32Sensors, icon: Icons.sensors_rounded),
                )),
              ),
              const SizedBox(height: 8),
              _NodeItem(
                icon: Icons.remove_red_eye_rounded,
                title: 'Tapo C110',
                role: 'Cámara IP RTSP (independiente, no pasa por la ESP32-S3)',
                link: config.of(HardwareNode.tapoCam),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const NodeDetailScreen(node: HardwareNode.tapoCam, icon: Icons.remove_red_eye_rounded),
                )),
              ),
              const SizedBox(height: 8),
              const _StaticNodeItem(
                icon: Icons.settings_input_component_rounded,
                title: 'BTS7960',
                role: 'Actuación / Motores',
                subtitle: 'Depende del ESP32-S3',
              ),
              const SizedBox(height: 8),
              const _StaticNodeItem(
                icon: Icons.wifi_rounded,
                title: 'RED',
                role: 'Wi-Fi / 4G LTE',
                subtitle: 'Conexión del teléfono',
                online: true,
              ),
              const SizedBox(height: 14),
              if (config.allOnline)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                  decoration: BoxDecoration(
                    color: const Color(0x147FA57A),
                    border: Border.all(color: const Color(0x407FA57A)),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.check_circle_rounded, size: 16, color: AppColors.green),
                      SizedBox(width: 8),
                      Text('Todos los nodos vinculados', style: TextStyle(color: AppColors.green, fontWeight: FontWeight.w600, fontSize: 12.5)),
                    ],
                  ),
                )
              else
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                  decoration: BoxDecoration(
                    color: const Color(0x14B59A55),
                    border: Border.all(color: const Color(0x40B59A55)),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.info_outline_rounded, size: 16, color: AppColors.yellow),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Vinculación pendiente: configura las IP de cada ESP en Sistema > Conexiones.',
                          style: TextStyle(color: AppColors.yellow, fontWeight: FontWeight.w600, fontSize: 12.5),
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 18),
              PrimaryButton(
                label: 'Ir a control del carrito',
                onPressed: () => state.showScreen(ScreenNames.control),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _TopologyDiagram extends StatelessWidget {
  const _TopologyDiagram();

  @override
  Widget build(BuildContext context) {
    Widget node(String label, {bool app = false, bool leaf = false}) {
      return Container(
        padding: EdgeInsets.symmetric(horizontal: leaf ? 10 : 14, vertical: leaf ? 8 : 9),
        decoration: BoxDecoration(
          color: app ? AppColors.orangeDim : AppColors.surface2,
          border: Border.all(color: app ? AppColors.orangeDim2 : AppColors.line),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: leaf ? 10.5 : 11.5,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.3,
            color: app ? AppColors.orange : (leaf ? AppColors.text2 : AppColors.text1),
          ),
        ),
      );
    }

    Widget vlink() => Container(width: 1.5, height: 22, color: AppColors.line);

    return AppCard(
      padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 14),
      child: Column(
        children: [
          node('APP FLUTTER', app: true),
          vlink(),
          node('ESP32-S3 BASE'),
          vlink(),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              node('ESP32-CAM', leaf: true),
              node('ESP32', leaf: true),
              node('BTS7960', leaf: true),
            ],
          ),
          const SizedBox(height: 6),
          const Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _LeafLabel('Video'),
              _LeafLabel('Sensores/LEDs'),
              _LeafLabel('Motores'),
            ],
          ),
        ],
      ),
    );
  }
}

class _LeafLabel extends StatelessWidget {
  final String text;
  const _LeafLabel(this.text);
  @override
  Widget build(BuildContext context) => SizedBox(
        width: 78,
        child: Text(text, textAlign: TextAlign.center, style: const TextStyle(fontSize: 9.5, color: AppColors.text3)),
      );
}

class _NodeItem extends StatelessWidget {
  final IconData icon;
  final String title;
  final String role;
  final NodeLink link;
  final VoidCallback onTap;

  const _NodeItem({required this.icon, required this.title, required this.role, required this.link, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final color = switch (link.status) {
      LinkStatus.online => AppColors.green,
      LinkStatus.connecting => AppColors.yellow,
      LinkStatus.error => AppColors.red,
      LinkStatus.pending => AppColors.text3,
    };
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: AppColors.surface1,
            border: Border.all(color: AppColors.lineSoft),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(color: AppColors.orangeDim, borderRadius: BorderRadius.circular(10)),
                child: Icon(icon, size: 18, color: AppColors.orange),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: AppColors.text1)),
                    Text(role, style: const TextStyle(fontSize: 11.5, color: AppColors.text2)),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Row(
                    children: [
                      Container(width: 6, height: 6, margin: const EdgeInsets.only(right: 5), decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
                      Text(link.statusLabel, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color)),
                    ],
                  ),
                  if (link.latencyMs != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text('${link.latencyMs} ms', style: const TextStyle(fontSize: 10, color: AppColors.text3, fontFamily: 'JetBrainsMono')),
                    ),
                ],
              ),
              const SizedBox(width: 4),
              const Icon(Icons.chevron_right_rounded, size: 18, color: AppColors.text3),
            ],
          ),
        ),
      ),
    );
  }
}

class _StaticNodeItem extends StatelessWidget {
  final IconData icon;
  final String title;
  final String role;
  final String subtitle;
  final bool online;

  const _StaticNodeItem({
    required this.icon,
    required this.title,
    required this.role,
    required this.subtitle,
    this.online = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = online ? AppColors.green : AppColors.text3;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.surface1,
        border: Border.all(color: AppColors.lineSoft),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(color: AppColors.orangeDim, borderRadius: BorderRadius.circular(10)),
            child: Icon(icon, size: 18, color: AppColors.orange),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: AppColors.text1)),
                Text(role, style: const TextStyle(fontSize: 11.5, color: AppColors.text2)),
              ],
            ),
          ),
          Row(
            children: [
              Container(width: 6, height: 6, margin: const EdgeInsets.only(right: 5), decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
              Text(subtitle, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color)),
            ],
          ),
        ],
      ),
    );
  }
}
