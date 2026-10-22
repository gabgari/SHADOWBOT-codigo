import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_theme.dart';
import '../services/dance_songs.dart';
import '../state/app_state.dart';
import '../state/auto_route.dart';
import '../state/bot_link.dart';
import 'common.dart';
import 'hud.dart';

/// Panel "MODOS" de la consola: la app hace todo lo que hace el mando de PS4
/// (elegir modo en el carrusel, entrar, salir al menú, velocidad de
/// exploración, bailes, faros…). El DS4 queda como un extra: si se pierde o
/// se descarga, el carrito se opera completo desde aquí.
///
/// El estado (modo, página del carrusel, velocidad) se lee de /estado vía
/// [BotLink], así que también refleja lo que se haga desde el mando.
class ModesCard extends StatelessWidget {
  const ModesCard({super.key});

  static const _modes = [
    ('menu', 'MENÚ', Icons.apps_rounded),
    ('sport', 'SPORT', Icons.speed_rounded),
    ('exploracion', 'EXPLORA', Icons.travel_explore_rounded),
    ('juego', 'DANCE', Icons.graphic_eq_rounded),
  ];

  static const _pages = ['CARÁTULA', 'SPORT', 'EXPLORACIÓN', 'DANCE'];

  @override
  Widget build(BuildContext context) {
    final u = context.u;
    final state = context.watch<AppState>();
    final link = context.watch<BotLink>();
    final locked = state.controlLocked;
    final online = link.estado != null;
    final mode = link.botMode;

    Widget body;
    switch (mode) {
      case 'menu':
        body = _MenuCarousel(page: link.estado?.pag ?? 0, pages: _pages);
      case 'sport':
        body = const _SportBody();
      case 'exploracion':
        body = _ExploraBody(vel: link.estado?.vel ?? 60);
      case 'juego':
        body = const _DanceBody();
      default:
        body = Text(
          online ? 'Modo STANDARD — elige un modo arriba.' : 'Sin enlace con CONTROL.',
          style: const TextStyle(fontSize: 10.5, color: AppColors.text3),
        );
    }

    return IgnorePointer(
      ignoring: locked || !online,
      child: Opacity(
        opacity: locked || !online ? 0.45 : 1,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                for (var i = 0; i < _modes.length; i++) ...[
                  if (i > 0) SizedBox(width: 4 * u),
                  Expanded(
                    child: _ModeButton(
                      label: _modes[i].$2,
                      icon: _modes[i].$3,
                      active: mode == _modes[i].$1,
                      onTap: () => link.setMode(_modes[i].$1),
                    ),
                  ),
                ],
              ],
            ),
            SizedBox(height: 10 * u),
            body,
            if (mode != null && mode != 'menu' && mode != 'off') ...[
              SizedBox(height: 8 * u),
              _WideButton(icon: Icons.keyboard_return_rounded, label: 'SALIR AL MENÚ', onTap: () => link.pad('l2x2')),
            ],
            // Luz del LCD 16x2 de CONTROL (solo on/off; también L2 + Options).
            if (link.lcdLuz != null) ...[
              SizedBox(height: 6 * u),
              _WideButton(
                icon: link.lcdLuz! ? Icons.light_mode_rounded : Icons.light_mode_outlined,
                label: !(link.estado?.lcdOk ?? false)
                    ? 'LCD SIN CONEXIÓN'
                    : (link.lcdLuz! ? 'LUZ LCD · ON' : 'LUZ LCD · OFF'),
                active: link.lcdLuz!,
                onTap: link.toggleLcdLight,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ModeButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool active;
  final VoidCallback onTap;
  const _ModeButton({required this.label, required this.icon, required this.active, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final u = context.u;
    return Material(
      color: active ? AppColors.militaryDark.withValues(alpha: 0.85) : AppColors.ink.withValues(alpha: 0.5),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.sm),
        side: BorderSide(color: active ? AppColors.military : AppColors.line),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 7 * u),
          child: Column(
            children: [
              Icon(icon, size: 15 * u, color: active ? AppColors.olive : AppColors.text2),
              SizedBox(height: 3 * u),
              FittedBox(child: Text(label, style: AppText.label.copyWith(fontSize: 8, color: active ? AppColors.text1 : AppColors.text2))),
            ],
          ),
        ),
      ),
    );
  }
}

class _WideButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool active;
  final bool danger;
  const _WideButton({required this.icon, required this.label, this.onTap, this.active = false, this.danger = false});

  @override
  Widget build(BuildContext context) {
    final u = context.u;
    final border = danger ? AppColors.red : (active ? AppColors.military : AppColors.line);
    final fg = danger ? AppColors.red : (active ? AppColors.text1 : AppColors.text2);
    return Material(
      color: active ? AppColors.militaryDark.withValues(alpha: 0.7) : AppColors.ink.withValues(alpha: 0.5),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.sm), side: BorderSide(color: border)),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 8 * u, vertical: 8 * u),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 14 * u, color: fg),
              SizedBox(width: 6 * u),
              Flexible(child: Text(label, overflow: TextOverflow.ellipsis, style: AppText.label.copyWith(fontSize: 9, color: fg))),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------- MENÚ: el carrusel de la pantalla redonda ----------------

class _MenuCarousel extends StatelessWidget {
  final int page;
  final List<String> pages;
  const _MenuCarousel({required this.page, required this.pages});

  @override
  Widget build(BuildContext context) {
    final u = context.u;
    final link = context.read<BotLink>();
    final p = page.clamp(0, pages.length - 1);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            HudIconButton(icon: Icons.chevron_left_rounded, size: 32, tooltip: 'Página anterior', onTap: () => link.pad('swipe_l')),
            Expanded(
              child: Column(
                children: [
                  Text(pages[p], style: AppText.value.copyWith(fontSize: 13)),
                  SizedBox(height: 4 * u),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      for (var i = 0; i < pages.length; i++)
                        Container(
                          width: (i == p ? 10 : 5) * u,
                          height: 5 * u,
                          margin: EdgeInsets.symmetric(horizontal: 2 * u),
                          decoration: BoxDecoration(
                            color: i == p ? AppColors.olive : AppColors.surface3,
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            HudIconButton(icon: Icons.chevron_right_rounded, size: 32, tooltip: 'Página siguiente', onTap: () => link.pad('swipe_r')),
          ],
        ),
        SizedBox(height: 8 * u),
        _WideButton(
          icon: Icons.login_rounded,
          label: p == 0 ? 'ELIGE UN MODO' : 'ENTRAR A ${pages[p]}',
          active: p != 0,
          onTap: p == 0 ? null : () => link.pad('r1x2'),
        ),
      ],
    );
  }
}

// ---------------- SPORT / EXPLORACIÓN: faros y gadgets ----------------

class _LedsRow extends StatelessWidget {
  const _LedsRow();

  @override
  Widget build(BuildContext context) {
    final u = context.u;
    final state = context.watch<AppState>();
    final all = state.ledOn.every((v) => v);
    return Row(
      children: [
        for (var i = 0; i < 4; i++) ...[
          Expanded(
            child: _WideButton(
              icon: Icons.lightbulb_outline_rounded,
              label: '${i + 1}',
              active: state.ledOn[i],
              onTap: () => state.toggleLed(i + 1),
            ),
          ),
          SizedBox(width: 4 * u),
        ],
        Expanded(
          flex: 2,
          child: _WideButton(icon: Icons.highlight_rounded, label: 'FAROS', active: all, onTap: () => state.setAllLeds(!all)),
        ),
      ],
    );
  }
}

class _SportBody extends StatelessWidget {
  const _SportBody();

  @override
  Widget build(BuildContext context) {
    final u = context.u;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('Velocidad máxima, como carrito RC.', style: TextStyle(fontSize: 10.5, color: AppColors.text3)),
        SizedBox(height: 8 * u),
        Text('LEDS', style: AppText.label.copyWith(fontSize: 8.5)),
        SizedBox(height: 4 * u),
        const _LedsRow(),
      ],
    );
  }
}

class _ExploraBody extends StatelessWidget {
  final int vel;
  const _ExploraBody({required this.vel});

  @override
  Widget build(BuildContext context) {
    final u = context.u;
    final state = context.watch<AppState>();
    final link = context.read<BotLink>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text('VELOCIDAD', style: AppText.label.copyWith(fontSize: 8.5)),
            const Spacer(),
            HudIconButton(icon: Icons.remove_rounded, size: 28, onTap: () => link.setExploraVel(vel - 20)),
            SizedBox(width: 8 * u),
            SizedBox(width: 42 * u, child: Center(child: Text('$vel%', style: AppText.value.copyWith(fontSize: 13)))),
            SizedBox(width: 8 * u),
            HudIconButton(icon: Icons.add_rounded, size: 28, onTap: () => link.setExploraVel(vel + 20)),
          ],
        ),
        SizedBox(height: 6 * u),
        BarMeter(value: vel / 100, color: AppColors.olive),
        SizedBox(height: 10 * u),
        Row(
          children: [
            Expanded(
              child: _WideButton(
                icon: Icons.panorama_horizontal_rounded,
                label: state.scanning ? 'ESCANEANDO' : 'ESCANEO',
                active: state.scanning,
                onTap: state.armScan,
              ),
            ),
            SizedBox(width: 4 * u),
            Expanded(child: _WideButton(icon: Icons.undo_rounded, label: 'RETROCESO', onTap: state.shortRetreat)),
          ],
        ),
        SizedBox(height: 6 * u),
        const _LedsRow(),
        SizedBox(height: 6 * u),
        const _AutonomoPanel(),
      ],
    );
  }
}

/// Sub-modo AUTÓNOMO de EXPLORACIÓN: se maneja normal, pero se puede trazar
/// la ruta y pedir el regreso inteligente (ver [AutoRoute]).
class _AutonomoPanel extends StatelessWidget {
  const _AutonomoPanel();

  @override
  Widget build(BuildContext context) {
    final u = context.u;
    final auto = context.watch<AutoRoute>();
    final secs = (auto.routeMs / 1000).toStringAsFixed(1);

    if (!auto.autonomo) {
      return _WideButton(icon: Icons.smart_toy_outlined, label: 'AUTÓNOMO', onTap: () => auto.setAutonomo(true));
    }

    final String info;
    if (auto.returning) {
      info = auto.lastMessage ?? 'Regresando…';
    } else if (auto.recording) {
      info = 'Trazando ruta · ${auto.segments.length} tramos · $secs s';
    } else if (auto.hasRoute) {
      info = 'Ruta lista · ${auto.segments.length} tramos · $secs s';
    } else {
      info = auto.lastMessage ?? 'Maneja normal. Toca TRAZAR RUTA al empezar.';
    }

    return Container(
      padding: EdgeInsets.all(6 * u),
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.military),
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.smart_toy_outlined, size: 13 * u, color: AppColors.olive),
              SizedBox(width: 5 * u),
              Text('AUTÓNOMO', style: AppText.label.copyWith(fontSize: 8.5, color: AppColors.text1)),
              const Spacer(),
              HudIconButton(icon: Icons.close_rounded, size: 24, tooltip: 'Salir de autónomo', onTap: () => auto.setAutonomo(false)),
            ],
          ),
          SizedBox(height: 4 * u),
          Text(info, style: const TextStyle(fontSize: 10, color: AppColors.text3)),
          SizedBox(height: 6 * u),
          if (auto.returning) ...[
            BarMeter(value: auto.progress, color: AppColors.olive),
            SizedBox(height: 6 * u),
            _WideButton(icon: Icons.stop_rounded, label: 'DETENER REGRESO', danger: true, onTap: auto.cancelReturn),
          ] else
            Row(
              children: [
                Expanded(
                  child: _WideButton(
                    icon: auto.recording ? Icons.stop_circle_outlined : Icons.fiber_manual_record_rounded,
                    label: auto.recording ? 'FIN DE RUTA' : 'TRAZAR RUTA',
                    active: auto.recording,
                    onTap: auto.recording ? auto.stopRecording : auto.startRecording,
                  ),
                ),
                SizedBox(width: 4 * u),
                Expanded(
                  child: _WideButton(
                    icon: Icons.u_turn_left_rounded,
                    label: 'REGRESO INTELIGENTE',
                    active: auto.hasRoute,
                    onTap: auto.hasRoute || auto.recording ? auto.startReturn : null,
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

// ---------------- DANCE: los 4 del mando + los 2 con canción ----------------

class _DanceBody extends StatelessWidget {
  const _DanceBody();

  static const _padDances = [
    ('✕', 'GIRO LOCO'),
    ('○', 'ZIGZAG'),
    ('□', 'SÍ Y NO'),
    ('△', 'TWIST'),
  ];

  Future<void> _song(BuildContext context, BotLink link, DanceSong s) async {
    if (link.playing == s.n) {
      await link.stopFromApp();
      return;
    }
    final msg = await link.startFromApp(s);
    if (msg != null && context.mounted) showAppToast(context, msg);
  }

  @override
  Widget build(BuildContext context) {
    final u = context.u;
    final link = context.watch<BotLink>();
    final busy = (link.estado?.baile ?? 0) != 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 4 * u,
          crossAxisSpacing: 4 * u,
          childAspectRatio: 3.4,
          children: [
            for (var i = 0; i < _padDances.length; i++)
              _WideButton(
                icon: Icons.music_off_outlined,
                label: '${_padDances[i].$1}  ${_padDances[i].$2}',
                active: link.estado?.baile == i + 1,
                onTap: busy ? null : () => link.pad('baile${i + 1}'),
              ),
          ],
        ),
        for (final s in danceSongs) _SongRow(song: s, playing: link.playing == s.n, starting: link.starting == s.n, onTap: () => _song(context, link, s)),
        SizedBox(height: 6 * u),
        _WideButton(icon: Icons.stop_rounded, label: 'PARAR BAILE', danger: busy, onTap: busy ? () => link.pad('baile_stop') : null),
      ],
    );
  }
}

class _SongRow extends StatelessWidget {
  final DanceSong song;
  final bool playing;
  final bool starting;
  final VoidCallback onTap;
  const _SongRow({required this.song, required this.playing, required this.starting, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final u = context.u;
    return Container(
      margin: EdgeInsets.only(top: 6 * u),
      padding: EdgeInsets.fromLTRB(10 * u, 5 * u, 5 * u, 5 * u),
      decoration: BoxDecoration(
        color: playing ? AppColors.militaryDark.withValues(alpha: 0.5) : AppColors.ink.withValues(alpha: 0.5),
        border: Border.all(color: playing ? AppColors.military : AppColors.lineSoft),
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Row(
        children: [
          Icon(Icons.music_note_rounded, size: 14 * u, color: playing ? AppColors.olive : AppColors.text2),
          SizedBox(width: 8 * u),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(song.title.toUpperCase(), style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.text1, letterSpacing: 0.8)),
                Text('${song.artist} · mando ${song.padKey}', style: const TextStyle(fontSize: 9.5, color: AppColors.text3), overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          starting
              ? SizedBox(
                  width: 28 * u,
                  height: 28 * u,
                  child: Padding(padding: EdgeInsets.all(7 * u), child: const CircularProgressIndicator(strokeWidth: 1.5)),
                )
              : HudIconButton(icon: playing ? Icons.stop_rounded : Icons.play_arrow_rounded, size: 28, active: playing, danger: playing, onTap: onTap),
        ],
      ),
    );
  }
}
