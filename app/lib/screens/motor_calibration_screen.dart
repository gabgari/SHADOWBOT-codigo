import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_theme.dart';
import '../state/app_state.dart';
import '../widgets/common.dart';
import '../widgets/top_bar.dart';

/// Calibración de los 2 BTS7960: el % de cada motor queda como base y la
/// velocidad general (consola, mando, modos) se aplica encima, como siempre.
class MotorCalibrationScreen extends StatelessWidget {
  const MotorCalibrationScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();

    Widget motor(String title, int value, void Function(int) onChanged) => AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(child: Text(title, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: AppColors.text1))),
                  IconButton(icon: const Icon(Icons.remove_rounded, color: AppColors.text1), onPressed: () => onChanged(value - 1)),
                  SizedBox(
                    width: 64,
                    child: Center(
                      child: Text('$value %', style: const TextStyle(fontFamily: AppFonts.mono, fontSize: 20, fontWeight: FontWeight.w600, color: AppColors.text1)),
                    ),
                  ),
                  IconButton(icon: const Icon(Icons.add_rounded, color: AppColors.text1), onPressed: () => onChanged(value + 1)),
                ],
              ),
              Slider(
                value: value.toDouble(),
                min: 30,
                max: 100,
                divisions: 70,
                activeColor: AppColors.orange,
                onChanged: (v) => onChanged(v.round()),
              ),
            ],
          ),
        );

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            ScreenTopBar(title: 'Calibración de motores', onBack: () => Navigator.of(context).pop()),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                children: [
                  const Text(
                    'Si un BTS7960 empuja más que el otro, el carrito se va de lado. Bájale el % al motor MÁS FUERTE hasta que avance derecho. Esto queda como base y la velocidad de siempre (consola, mando, modos) se aplica encima.',
                    style: TextStyle(fontSize: 12.5, color: AppColors.text2, fontWeight: FontWeight.w500),
                  ),
                  const SectionTitle('BTS7960 izquierdo'),
                  motor('Motor IZQUIERDO', state.trimL, (v) => state.setMotorTrim(left: v)),
                  const SectionTitle('BTS7960 derecho'),
                  motor('Motor DERECHO', state.trimR, (v) => state.setMotorTrim(right: v)),
                  const SectionTitle('Probar'),
                  AppCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          state.controlLocked
                              ? 'Primero presiona INICIAR en Conexiones.'
                              : 'Pon el carrito en el piso con espacio: avanza 2 s a la velocidad actual (${state.speed} %). Si se va a la derecha, el motor IZQUIERDO es el fuerte; si se va a la izquierda, el DERECHO.',
                          style: const TextStyle(fontSize: 10.5, color: AppColors.text3),
                        ),
                        const SizedBox(height: 10),
                        PrimaryButton(
                          label: 'Avanzar 2 s',
                          icon: Icons.straight_rounded,
                          onPressed: state.controlLocked ? null : () => state.testDriveStraight(),
                        ),
                        const SizedBox(height: 8),
                        GhostButton(
                          label: 'Restablecer (100 % / 100 %)',
                          onPressed: () => state.setMotorTrim(left: 100, right: 100),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'Se guarda en el teléfono. Los bailes los ejecuta CONTROL por su cuenta y no usan esta calibración.',
                    style: TextStyle(fontSize: 10, color: AppColors.text3),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
