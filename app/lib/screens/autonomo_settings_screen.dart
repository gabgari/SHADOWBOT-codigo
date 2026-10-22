import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_theme.dart';
import '../state/app_state.dart';
import '../state/auto_route.dart';
import '../widgets/common.dart';
import '../widgets/top_bar.dart';

/// Ajustes del modo AUTÓNOMO (regreso inteligente) y del brazo.
class AutonomoSettingsScreen extends StatelessWidget {
  const AutonomoSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final auto = context.watch<AutoRoute>();
    final state = context.watch<AppState>();

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            ScreenTopBar(title: 'Exploración autónoma', onBack: () => Navigator.of(context).pop()),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                children: [
                  const Text(
                    'El regreso inteligente repite la ruta grabada al revés. Para la media vuelta usa el tiempo que tarda el carrito en girar sobre su eje — no hay sensor, así que lo mides tú.',
                    style: TextStyle(fontSize: 12.5, color: AppColors.text2, fontWeight: FontWeight.w500),
                  ),
                  const SectionTitle('Segundos en dar una vuelta'),
                  AppCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'En EXPLORACIÓN a ${AutoRoute.calibVel}% (la velocidad de fábrica), haz girar el carrito sobre su eje y cronometra con un video cuánto tarda en dar una vuelta COMPLETA (360°).',
                          style: TextStyle(fontSize: 10.5, color: AppColors.text3),
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            IconButton(
                              icon: const Icon(Icons.remove_rounded, color: AppColors.text1),
                              onPressed: () => auto.setTurnSecs(auto.turnSecs - 0.1),
                            ),
                            Expanded(
                              child: Center(
                                child: Text('${auto.turnSecs.toStringAsFixed(1)} s',
                                    style: const TextStyle(fontFamily: AppFonts.mono, fontSize: 26, fontWeight: FontWeight.w600, color: AppColors.text1)),
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.add_rounded, color: AppColors.text1),
                              onPressed: () => auto.setTurnSecs(auto.turnSecs + 0.1),
                            ),
                          ],
                        ),
                        Slider(
                          value: auto.turnSecs.clamp(0.5, 15.0),
                          min: 0.5,
                          max: 15,
                          divisions: 145,
                          activeColor: AppColors.orange,
                          onChanged: auto.setTurnSecs,
                        ),
                        const SizedBox(height: 4),
                        PrimaryButton(
                          label: auto.returning ? 'Girando…' : 'Probar vuelta',
                          icon: Icons.threesixty_rounded,
                          onPressed: auto.returning
                              ? null
                              : () async {
                                  final msg = await auto.testTurn();
                                  if (msg != null && context.mounted) showAppToast(context, msg);
                                },
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          'Si se pasa de la vuelta, baja los segundos; si se queda corto, súbelos.',
                          style: TextStyle(fontSize: 10, color: AppColors.text3),
                        ),
                      ],
                    ),
                  ),
                  const SectionTitle('Regreso'),
                  AppCard(
                    child: SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: const Text('Girar al llegar', style: TextStyle(fontSize: 13, color: AppColors.text1)),
                      subtitle: const Text('Otra media vuelta al terminar, para quedar mirando hacia donde empezó la ruta.',
                          style: TextStyle(fontSize: 10, color: AppColors.text3)),
                      value: auto.finalTurn,
                      activeThumbColor: AppColors.orange,
                      onChanged: auto.setFinalTurn,
                    ),
                  ),
                  const SectionTitle('Brazo de la cámara'),
                  AppCard(
                    child: SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: const Text('Invertir giro de la base (PAN)', style: TextStyle(fontSize: 13, color: AppColors.text1)),
                      subtitle: const Text('Si al pedir izquierda la cámara gira a la derecha. Se guarda en el teléfono (no hay que flashear).',
                          style: TextStyle(fontSize: 10, color: AppColors.text3)),
                      value: state.invertPan,
                      activeThumbColor: AppColors.orange,
                      onChanged: state.setInvertPan,
                    ),
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
