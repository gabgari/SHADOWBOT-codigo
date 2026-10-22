import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_theme.dart';
import '../models/node_link.dart';
import '../services/device_config.dart';
import '../state/app_state.dart';
import '../widgets/common.dart';
import '../widgets/top_bar.dart';

/// Detalle de un nodo de hardware: estado y latencia REALES (medidos con
/// un ping HTTP real, ver `AppState.pingNode`) — nada simulado. Se llega
/// tocando cualquier nodo en `NodosScreen`.
class NodeDetailScreen extends StatefulWidget {
  final HardwareNode node;
  final IconData icon;
  const NodeDetailScreen({super.key, required this.node, required this.icon});

  @override
  State<NodeDetailScreen> createState() => _NodeDetailScreenState();
}

class _NodeDetailScreenState extends State<NodeDetailScreen> {
  bool _pinging = false;

  Future<void> _probar(AppState state) async {
    setState(() => _pinging = true);
    await state.pingNode(widget.node);
    if (mounted) setState(() => _pinging = false);
  }

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    final config = context.watch<DeviceConfig>();
    final link = config.of(widget.node);
    final color = switch (link.status) {
      LinkStatus.online => AppColors.green,
      LinkStatus.connecting => AppColors.yellow,
      LinkStatus.error => AppColors.red,
      LinkStatus.pending => AppColors.text3,
    };

    // Scaffold es necesario: esta pantalla se abre con Navigator.push, no
    // vive dentro del Scaffold de RootShell — sin el suyo propio, el texto
    // pierde el ancestro Material y Flutter lo pinta con su estilo de
    // emergencia (amarillo subrayado, a propósito, para delatar el bug).
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            ScreenTopBar(
              title: link.label,
              onBack: () => Navigator.of(context).pop(),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 18),
                children: [
                  AppCard(
                    child: Column(
                      children: [
                        Container(
                          width: 56,
                          height: 56,
                          decoration: BoxDecoration(
                            color: AppColors.orangeDim,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Icon(
                            widget.icon,
                            size: 26,
                            color: AppColors.orange,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          link.label,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                            color: AppColors.text1,
                          ),
                        ),
                        Text(
                          link.role,
                          style: const TextStyle(
                            fontSize: 12,
                            color: AppColors.text2,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: color.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 7,
                                height: 7,
                                decoration: BoxDecoration(
                                  color: color,
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                link.statusLabel,
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: color,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SectionTitle('Datos reales'),
                  AppCard(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 4,
                    ),
                    child: Column(
                      children: [
                        _Row(
                          label: 'IP / host',
                          value: link.host.isEmpty
                              ? 'Sin configurar'
                              : link.host,
                        ),
                        const Divider(height: 1, color: AppColors.lineSoft),
                        _Row(
                          label: 'Latencia (ping real)',
                          value: link.latencyMs != null
                              ? '${link.latencyMs} ms'
                              : '—',
                          valueColor: link.latencyMs != null
                              ? AppColors.text1
                              : AppColors.text3,
                        ),
                        const Divider(height: 1, color: AppColors.lineSoft),
                        _Row(
                          label: 'Último chequeo',
                          value: link.lastChecked != null
                              ? _fmtTime(link.lastChecked!)
                              : 'Nunca',
                        ),
                      ],
                    ),
                  ),
                  if (link.host.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Text(
                        'Este nodo no tiene IP configurada. Ve a Sistema > Conexiones para vincularlo.',
                        style: const TextStyle(
                          fontSize: 11.5,
                          color: AppColors.yellow,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  const SizedBox(height: 18),
                  PrimaryButton(
                    label: _pinging ? 'Probando…' : 'Probar conexión ahora',
                    onPressed: (_pinging || link.host.isEmpty)
                        ? null
                        : () => _probar(state),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _fmtTime(DateTime t) {
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    final s = t.second.toString().padLeft(2, '0');
    return '$h:$m:$s';
  }
}

class _Row extends StatelessWidget {
  final String label;
  final String value;
  final Color valueColor;
  const _Row({
    required this.label,
    required this.value,
    this.valueColor = AppColors.text1,
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 12.5, color: AppColors.text2),
        ),
        Text(
          value,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w700,
            color: valueColor,
            fontFamily: 'JetBrainsMono',
          ),
        ),
      ],
    ),
  );
}
