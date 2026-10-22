import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_theme.dart';
import '../services/vision_service.dart';
import '../state/app_state.dart';
import '../widgets/common.dart';
import '../widgets/hud.dart';
import '../widgets/top_bar.dart';
import '../widgets/vision_widgets.dart';

/// Sistema › Visión IA: dirección (IP:puerto) de la PC que corre YOLO sobre
/// CAM 2, prueba de conexión y fuente de CAM 2.
class VisionSettingsScreen extends StatefulWidget {
  const VisionSettingsScreen({super.key});

  @override
  State<VisionSettingsScreen> createState() => _VisionSettingsScreenState();
}

class _VisionSettingsScreenState extends State<VisionSettingsScreen> {
  late final TextEditingController _host;
  bool _testing = false;

  @override
  void initState() {
    super.initState();
    _host = TextEditingController(text: context.read<AppState>().vision.manualHost);
  }

  @override
  void dispose() {
    _host.dispose();
    super.dispose();
  }

  Future<void> _saveAndTest(VisionService vision) async {
    setState(() => _testing = true);
    await vision.setHost(_host.text);
    _host.text = vision.manualHost;
    final ok = vision.available;
    if (!mounted) return;
    setState(() => _testing = false);
    showAppToast(context, ok ? 'PC de visión en línea (${vision.host})' : 'La PC de visión no responde en ${vision.host}');
  }

  @override
  Widget build(BuildContext context) {
    final vision = context.watch<AppState>().vision;
    return Scaffold(
      body: SafeArea(
        child: ListenableBuilder(
          listenable: vision,
          builder: (context, _) => Column(
            children: [
              ScreenTopBar(title: 'Visión IA', onBack: () => Navigator.of(context).pop()),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                  children: [
                    const Text(
                      'Una PC en la misma red Wi-Fi corre YOLO sobre CAM 2 (la Tapo) y publica el video con los recuadros del fuego. No siempre está encendida: si no responde, CAM 2 sigue por RTSP directo.',
                      style: TextStyle(fontSize: 12.5, color: AppColors.text2, fontWeight: FontWeight.w500),
                    ),
                    const SectionTitle('Búsqueda automática'),
                    AppCard(
                      child: Row(
                        children: [
                          vision.discoveredAt != null
                              ? const Icon(Icons.radar_rounded, size: 18, color: AppColors.green)
                              : const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 1.5)),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              vision.discoveredAt != null
                                  ? 'PC de visión encontrada: http://${vision.discoveredHost}'
                                  : (vision.discoveredHost.isEmpty
                                      ? 'Buscando PC de visión… (anuncio UDP, puerto 5001)'
                                      : 'Buscando PC de visión… (la última fue http://${vision.discoveredHost})'),
                              style: const TextStyle(fontSize: 12, color: AppColors.text1, fontWeight: FontWeight.w600),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SectionTitle('IP manual (respaldo)'),
                    AppCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Text(
                            'Opcional. Si escribes una IP y responde, se usa esa; si no responde, la que se encontró sola. Déjala vacía para usar solo la automática.',
                            style: TextStyle(fontSize: 10.5, color: AppColors.text3),
                          ),
                          const SizedBox(height: 8),
                          TextField(
                            controller: _host,
                            keyboardType: TextInputType.url,
                            style: const TextStyle(fontFamily: AppFonts.mono, color: AppColors.text1),
                            decoration: const InputDecoration(labelText: 'IP:puerto (vacío = automática)', hintText: VisionService.defaultHost),
                            onSubmitted: (_) => _saveAndTest(vision),
                          ),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              Expanded(
                                child: ElevatedButton.icon(
                                  onPressed: _testing ? null : () => _saveAndTest(vision),
                                  icon: _testing
                                      ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.5))
                                      : const Icon(Icons.wifi_tethering_rounded, size: 16),
                                  label: const Text('GUARDAR Y PROBAR'),
                                ),
                              ),
                              const SizedBox(width: 8),
                              OutlinedButton(
                                onPressed: _testing
                                    ? null
                                    : () {
                                        _host.clear();
                                        _saveAndTest(vision);
                                      },
                                child: const Text('SOLO AUTOMÁTICA'),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              StatusDot(color: vision.available ? AppColors.green : AppColors.yellow, size: 7),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  vision.available
                                      ? 'En línea · usando ${vision.host}${vision.host == vision.manualHost ? ' (manual)' : ' (automática)'}${vision.fps == null ? '' : ' · ${vision.fps!.toStringAsFixed(1)} fps'}'
                                      : 'No disponible (apagada, otra IP, o sin video de la cámara)',
                                  style: const TextStyle(fontSize: 11.5, color: AppColors.text1),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SectionTitle('Fuente de CAM 2'),
                    const AppCard(child: Cam2SourceSelector()),
                    const SizedBox(height: 10),
                    Text(
                      'Prueba: abre http://${vision.host}/video en el navegador del celular. Si ahí se ve el video con recuadros, la app también lo verá. En VISIÓN IA la app revisa /estado cada segundo y avisa (banner rojo + vibración) si hay fuego, como máximo una vez cada 10 s.',
                      style: const TextStyle(fontSize: 10.5, color: AppColors.text3),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
