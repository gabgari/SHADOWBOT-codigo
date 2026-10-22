import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_theme.dart';
import '../models/app_models.dart';
import '../models/node_link.dart';
import '../services/device_config.dart';
import '../state/app_state.dart';
import '../widgets/common.dart';
import '../widgets/gauge_ring.dart';
import '../widgets/top_bar.dart';

class SensoresScreen extends StatelessWidget {
  const SensoresScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final config = context.watch<DeviceConfig>();
    final sensorLink = config.of(HardwareNode.esp32Sensors);

    return Column(
      children: [
        ScreenTopBar(
          title: 'Sensores',
          onBack: () => state.showScreen(ScreenNames.inicio),
          statusLabel: sensorLink.statusLabel,
          online: sensorLink.isOnline,
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 18),
            children: [
              if (!sensorLink.isOnline)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: const Color(0x14B59A55),
                      border: Border.all(color: const Color(0x40B59A55)),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Text(
                      'ESP32 (sensores) no vinculado — mostrando datos de demostración.',
                      style: TextStyle(color: AppColors.yellow, fontSize: 12, fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
              const SectionTitle('LEDs'),
              if (state.controlLocked)
                const Padding(
                  padding: EdgeInsets.only(bottom: 10),
                  child: Text(
                    'Bloqueados hasta que presiones "Iniciar" en Sistema > Conexiones — antes de eso, estos mismos LEDs muestran qué nodos ya vinculaste.',
                    style: TextStyle(fontSize: 11, color: AppColors.text3),
                  ),
                ),
              IgnorePointer(
                ignoring: state.controlLocked,
                child: Opacity(
                  opacity: state.controlLocked ? 0.4 : 1,
                  child: _LedPanel(state: state),
                ),
              ),
              const SectionTitle('Gas · MQ-2'),
              _MqPanel(state: state),
            ],
          ),
        ),
      ],
    );
  }
}

class _MqPanel extends StatelessWidget {
  final AppState state;
  const _MqPanel({required this.state});

  @override
  Widget build(BuildContext context) {
    final readings = state.gasReadings.values.toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Con un solo sensor MQ conectado, una tarjeta ancha se ve mejor
        // que una grilla de 2 columnas con la mitad vacía.
        GridView.count(
          crossAxisCount: readings.length == 1 ? 1 : 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
          childAspectRatio: readings.length == 1 ? 2.4 : 0.92,
          children: readings.map((g) => _GasCard(reading: g)).toList(),
        ),
        const SectionTitle('Valores en tiempo real'),
        AppCard(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
          child: Column(
            children: [
              for (var i = 0; i < readings.length; i++) ...[
                _LiveRow(reading: readings[i]),
                if (i != readings.length - 1) const Divider(height: 1, color: AppColors.lineSoft),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _GasCard extends StatelessWidget {
  final GasReading reading;
  const _GasCard({required this.reading});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface1,
        border: Border.all(color: AppColors.lineSoft),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(reading.name, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: AppColors.text1)),
                Text(reading.type, style: const TextStyle(fontSize: 10, color: AppColors.text2)),
              ],
            ),
          ),
          const SizedBox(height: 8),
          GaugeRing(percent: reading.value, warn: reading.isWarn),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
            decoration: BoxDecoration(
              color: reading.isWarn ? const Color(0x1FB59A55) : const Color(0x1A7FA57A),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              reading.isWarn ? '⚠ Atención' : 'Normal',
              style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: reading.isWarn ? AppColors.yellow : AppColors.green),
            ),
          ),
        ],
      ),
    );
  }
}

class _LiveRow extends StatelessWidget {
  final GasReading reading;
  const _LiveRow({required this.reading});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Container(width: 7, height: 7, decoration: BoxDecoration(color: reading.isWarn ? AppColors.yellow : AppColors.green, shape: BoxShape.circle)),
          const SizedBox(width: 10),
          SizedBox(width: 56, child: Text(reading.name, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: AppColors.text1))),
          Expanded(
            child: Text('${reading.value.round()}%', style: const TextStyle(fontSize: 12.5, color: AppColors.text1, fontFamily: 'JetBrainsMono')),
          ),
          Text(reading.type, style: const TextStyle(fontSize: 10.5, color: AppColors.text3)),
        ],
      ),
    );
  }
}

class _LedPanel extends StatelessWidget {
  final AppState state;
  const _LedPanel({required this.state});

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Faros', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: AppColors.text1)),
              Row(
                children: [
                  TextButton(
                    onPressed: () => state.setAllLeds(true),
                    child: const Text('Todos ON', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700)),
                  ),
                  TextButton(
                    onPressed: () => state.setAllLeds(false),
                    child: const Text('Todos OFF', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700)),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: List.generate(
              4,
              (i) => _LedButton(
                number: i + 1,
                on: state.ledOn[i],
                onTap: () => state.toggleLed(i + 1),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LedButton extends StatelessWidget {
  final int number;
  final bool on;
  final VoidCallback onTap;
  const _LedButton({required this.number, required this.on, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: on ? AppColors.orangeDim : AppColors.surface2,
              shape: BoxShape.circle,
              border: Border.all(color: on ? AppColors.orange : AppColors.line, width: 2),
            ),
            child: Icon(Icons.lightbulb_rounded, color: on ? AppColors.orange : AppColors.text3, size: 26),
          ),
          const SizedBox(height: 6),
          Text(
            'LED $number',
            style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: on ? AppColors.orange : AppColors.text3),
          ),
        ],
      ),
    );
  }
}
