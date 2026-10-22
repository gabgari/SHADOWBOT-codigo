import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_theme.dart';
import '../state/app_state.dart';
import '../widgets/top_bar.dart';
import 'alertas_screen.dart';
import 'camara_screen.dart';
import 'control_screen.dart';
import 'gamepad_screen.dart';
import 'multimedia_screen.dart';
import 'nodos_screen.dart';
import 'sensores_screen.dart';
import 'sistema_screen.dart';

/// Contenedor raíz (horizontal, teléfono o tablet): barra superior HUD fija
/// con "SHADOW BOT / SECCIÓN" + estado del enlace, menú lateral de secciones
/// y una sola pantalla visible a la vez. La de inicio es la consola de
/// NAVEGACIÓN.
class RootShell extends StatelessWidget {
  const RootShell({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final screen = state.currentScreen;
    final isConsole = screen == ScreenNames.control || screen == ScreenNames.inicio;
    return Scaffold(
      backgroundColor: AppColors.ink,
      drawer: const HudDrawer(),
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Builder(
              builder: (ctx) => HudTopBar(
                section: sectionLabel(isConsole ? ScreenNames.control : screen),
                onMenu: () => Scaffold.of(ctx).openDrawer(),
                onSettings: () => state.showScreen(ScreenNames.sistema),
              ),
            ),
            Expanded(
              child: isConsole
                  ? const ControlScreen()
                  : DecoratedBox(
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [AppColors.bg, AppColors.ink],
                        ),
                      ),
                      // En tablets las listas no se estiran de lado a lado.
                      child: Align(
                        alignment: Alignment.topCenter,
                        child: ConstrainedBox(
                          constraints: BoxConstraints(maxWidth: 1000 * context.u),
                          child: _buildScreen(screen),
                        ),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildScreen(String screen) {
    switch (screen) {
      case ScreenNames.nodos:
        return const NodosScreen();
      case ScreenNames.sensores:
        return const SensoresScreen();
      case ScreenNames.sistema:
        return const SistemaScreen();
      case ScreenNames.camara:
        return const CamaraScreen();
      case ScreenNames.galeria:
        return const MultimediaScreen();
      case ScreenNames.alertas:
        return const AlertasScreen();
      case ScreenNames.mando:
        return const GamepadScreen();
      default:
        return const ControlScreen();
    }
  }
}
