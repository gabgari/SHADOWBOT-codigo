import 'dart:math';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_theme.dart';
import '../state/app_state.dart';
import '../state/bot_link.dart';
import '../state/gamepad_link.dart';
import '../widgets/hud.dart';
import '../widgets/top_bar.dart';

/// Pantalla "Mando": conectar el DS4 al teléfono, probarlo en vivo y ver
/// qué hace cada botón en cada modo. Todo es extra: la app funciona igual
/// sin mando.
class GamepadScreen extends StatefulWidget {
  const GamepadScreen({super.key});

  @override
  State<GamepadScreen> createState() => _GamepadScreenState();
}

class _GamepadScreenState extends State<GamepadScreen> {
  String? _viewMode; // null = el modo actual del bot

  @override
  Widget build(BuildContext context) {
    final u = context.u;
    final pad = context.watch<GamepadLink>();
    final botMode = context.watch<BotLink>().botMode;
    final mode = _viewMode ?? (const ['menu', 'sport', 'exploracion', 'juego'].contains(botMode) ? botMode! : 'menu');

    final left = [
      _ConnectionPanel(pad: pad),
      _SettingsPanel(pad: pad),
      _LogPanel(pad: pad),
    ];
    final right = [
      _LivePanel(pad: pad),
      _MappingPanel(
        mode: mode,
        current: botMode,
        onMode: (m) => setState(() => _viewMode = m),
      ),
    ];

    return Column(
      children: [
        ScreenTopBar(
          title: 'Mando · conectado al teléfono',
          statusLabel: pad.connected ? (pad.name ?? 'Mando') : 'Sin mando',
          online: pad.connected,
        ),
        Expanded(
          child: LayoutBuilder(builder: (context, c) {
            final gap = 10 * u;
            if (c.maxWidth < 700) {
              return ListView(
                padding: EdgeInsets.fromLTRB(16 * u, 0, 16 * u, 16 * u),
                children: [for (final p in [...left, ...right]) Padding(padding: EdgeInsets.only(bottom: gap), child: p)],
              );
            }
            return SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(16 * u, 0, 16 * u, 16 * u),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 4,
                    child: Column(children: [for (final p in left) Padding(padding: EdgeInsets.only(bottom: gap), child: p)]),
                  ),
                  SizedBox(width: gap),
                  Expanded(
                    flex: 6,
                    child: Column(children: [for (final p in right) Padding(padding: EdgeInsets.only(bottom: gap), child: p)]),
                  ),
                ],
              ),
            );
          }),
        ),
      ],
    );
  }
}

// =============================================================
//  Conexión
// =============================================================

class _ConnectionPanel extends StatelessWidget {
  final GamepadLink pad;
  const _ConnectionPanel({required this.pad});

  @override
  Widget build(BuildContext context) {
    final u = context.u;
    Widget step(String n, String text) => Padding(
          padding: EdgeInsets.only(top: 6 * u),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 18 * u,
                height: 18 * u,
                alignment: Alignment.center,
                decoration: BoxDecoration(border: Border.all(color: AppColors.line), borderRadius: BorderRadius.circular(4)),
                child: Text(n, style: AppText.label.copyWith(fontSize: 9, color: AppColors.text1)),
              ),
              SizedBox(width: 8 * u),
              Expanded(child: Text(text, style: const TextStyle(fontSize: 11.5, color: AppColors.text2, height: 1.35))),
            ],
          ),
        );

    return HudPanel(
      title: 'Conexión',
      icon: Icons.bluetooth_rounded,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              StatusDot(color: pad.statusColor, size: 8),
              SizedBox(width: 10 * u),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(pad.connected ? 'MANDO CONECTADO' : 'SIN MANDO', style: AppText.value.copyWith(fontSize: 13)),
                    if (pad.name != null && pad.connected)
                      Text(pad.name!, style: const TextStyle(fontSize: 11, color: AppColors.text2), overflow: TextOverflow.ellipsis),
                  ],
                ),
              ),
              Switch(value: pad.enabled, onChanged: pad.setEnabled),
            ],
          ),
          Text(
            pad.enabled ? 'El mando controla el carrito.' : 'Mando deshabilitado: se ignoran sus botones.',
            style: const TextStyle(fontSize: 10.5, color: AppColors.text3),
          ),
          SizedBox(height: 10 * u),
          Text('CÓMO CONECTARLO', style: AppText.label.copyWith(fontSize: 9)),
          step('1', 'En el teléfono: Ajustes › Bluetooth › Vincular dispositivo.'),
          step('2', 'En el DS4 mantén PS + Share hasta que la luz parpadee rápido.'),
          step('3', 'Elige "Wireless Controller". También sirve con cable USB-OTG.'),
          step('4', 'Presiona INICIAR en Conexiones: el mando queda bloqueado hasta entonces (PS = paro funciona siempre).'),
          SizedBox(height: 10 * u),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: pad.connected ? () => pad.rumble(300, 220) : null,
                  icon: Icon(Icons.vibration_rounded, size: 16 * u),
                  label: const Text('VIBRAR', style: TextStyle(fontFamily: AppFonts.mono, fontSize: 11)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// =============================================================
//  Prueba en vivo
// =============================================================

class _LivePanel extends StatelessWidget {
  final GamepadLink pad;
  const _LivePanel({required this.pad});

  @override
  Widget build(BuildContext context) {
    final u = context.u;
    const buttons = [
      ('A', '✕'), ('B', '○'), ('X', '□'), ('Y', '△'),
      ('R1', 'R1'), ('L2', 'L2'), ('R2', 'R2'),
      ('L3', 'L3'), ('R3', 'R3'), ('SHARE', 'SHARE'), ('OPTIONS', 'OPT'),
      ('UP', '↑'), ('DOWN', '↓'), ('LEFT', '←'), ('RIGHT', '→'), ('PS', 'PS'),
    ];
    Widget stick(String label, double x, double y) => Column(
          children: [
            SizedBox(width: 92 * u, height: 92 * u, child: CustomPaint(painter: _StickPainter(x, y))),
            SizedBox(height: 4 * u),
            Text(label, style: AppText.label.copyWith(fontSize: 8.5)),
          ],
        );
    Widget trig(String label, double v) => Row(
          children: [
            SizedBox(width: 24 * u, child: Text(label, style: AppText.label.copyWith(fontSize: 9))),
            Expanded(child: BarMeter(value: v, color: AppColors.olive)),
          ],
        );

    return HudPanel(
      title: 'Prueba en vivo',
      icon: Icons.sports_esports_outlined,
      trailing: Text('MOTORES ${pad.driveL} / ${pad.driveR}', style: AppText.label.copyWith(fontSize: 9, color: AppColors.text1)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              stick('STICK IZQ · MANEJO', pad.lx, pad.ly),
              Expanded(
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 14 * u),
                  child: Column(children: [trig('L2', pad.lt), SizedBox(height: 10 * u), trig('R2', pad.rt)]),
                ),
              ),
              stick('STICK DER · BRAZO', pad.rx, pad.ry),
            ],
          ),
          SizedBox(height: 12 * u),
          Wrap(
            spacing: 5 * u,
            runSpacing: 5 * u,
            children: [
              for (final b in buttons)
                Container(
                  constraints: BoxConstraints(minWidth: 34 * u),
                  padding: EdgeInsets.symmetric(horizontal: 7 * u, vertical: 5 * u),
                  decoration: BoxDecoration(
                    color: pad.held.contains(b.$1) ? AppColors.militaryDark : AppColors.ink.withValues(alpha: 0.5),
                    border: Border.all(color: pad.held.contains(b.$1) ? AppColors.olive : AppColors.line),
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                  ),
                  child: Text(b.$2, textAlign: TextAlign.center, style: AppText.label.copyWith(fontSize: 10, color: pad.held.contains(b.$1) ? AppColors.text1 : AppColors.text3)),
                ),
            ],
          ),
          if (!pad.connected) ...[
            SizedBox(height: 8 * u),
            const Text('Conecta el mando para ver aquí los sticks y botones.', style: TextStyle(fontSize: 10.5, color: AppColors.text3)),
          ],
        ],
      ),
    );
  }
}

class _StickPainter extends CustomPainter {
  final double x, y;
  _StickPainter(this.x, this.y);

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2 - 2;
    canvas.drawCircle(c, r, Paint()..color = AppColors.ink);
    final line = Paint()
      ..color = AppColors.line
      ..style = PaintingStyle.stroke;
    canvas.drawCircle(c, r, line);
    canvas.drawCircle(c, r * 0.14 * 2, line); // zona muerta aprox.
    canvas.drawLine(Offset(c.dx - r, c.dy), Offset(c.dx + r, c.dy), line);
    canvas.drawLine(Offset(c.dx, c.dy - r), Offset(c.dx, c.dy + r), line);
    final p = c + Offset(x.clamp(-1.0, 1.0), y.clamp(-1.0, 1.0)) * (r - 8);
    final moving = sqrt(x * x + y * y) > 0.14;
    canvas.drawCircle(p, 8, Paint()..color = moving ? AppColors.olive : AppColors.text3);
  }

  @override
  bool shouldRepaint(covariant _StickPainter old) => old.x != x || old.y != y;
}

// =============================================================
//  Qué hace cada botón
// =============================================================

class _MappingPanel extends StatelessWidget {
  final String mode;
  final String? current;
  final ValueChanged<String> onMode;
  const _MappingPanel({required this.mode, required this.current, required this.onMode});

  @override
  Widget build(BuildContext context) {
    final u = context.u;
    Widget row((String, String) r, {bool strong = false}) => Container(
          padding: EdgeInsets.symmetric(vertical: 6 * u),
          decoration: const BoxDecoration(border: Border(top: BorderSide(color: AppColors.lineSoft))),
          child: Row(
            children: [
              SizedBox(width: 110 * u, child: Text(r.$1, style: AppText.value.copyWith(fontSize: 11.5, color: strong ? AppColors.text1 : AppColors.text2))),
              Expanded(child: Text(r.$2, style: TextStyle(fontSize: 11.5, color: r.$1.isEmpty ? AppColors.text3 : AppColors.text1))),
            ],
          ),
        );

    return HudPanel(
      title: 'Qué hace cada botón',
      icon: Icons.list_alt_rounded,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 6 * u,
            runSpacing: 6 * u,
            children: [
              for (final m in const ['menu', 'sport', 'exploracion', 'juego'])
                HudChip(
                  text: BotLink.modeLabel(m) + (m == current ? ' ●' : ''),
                  active: m == mode,
                  onTap: () => onMode(m),
                ),
            ],
          ),
          SizedBox(height: 10 * u),
          Text('EN ${BotLink.modeLabel(mode)}', style: AppText.label.copyWith(fontSize: 9)),
          for (final r in GamepadLink.mapByMode[mode]!) row(r, strong: true),
          SizedBox(height: 10 * u),
          Text('EN TODOS LOS MODOS', style: AppText.label.copyWith(fontSize: 9)),
          for (final r in GamepadLink.mapAlways) row(r),
          SizedBox(height: 10 * u),
          Text('COMBOS (MANTÉN L2)', style: AppText.label.copyWith(fontSize: 9)),
          for (final r in GamepadLink.mapCombos) row(r),
        ],
      ),
    );
  }
}

// =============================================================
//  Ajustes
// =============================================================

class _SettingsPanel extends StatelessWidget {
  final GamepadLink pad;
  const _SettingsPanel({required this.pad});

  @override
  Widget build(BuildContext context) {
    final u = context.u;
    final s = pad.settings;
    context.watch<AppState>(); // la velocidad es la de la app

    Widget slider(String label, int value, int min, int max, String unit, void Function(int v) onChanged) => Padding(
          padding: EdgeInsets.only(top: 6 * u),
          child: Row(
            children: [
              SizedBox(width: 120 * u, child: Text(label, style: AppText.label.copyWith(fontSize: 9))),
              Expanded(
                child: SizedBox(
                  height: 26 * u,
                  child: Slider(
                    value: value.toDouble(),
                    min: min.toDouble(),
                    max: max.toDouble(),
                    divisions: max - min,
                    onChanged: (v) => onChanged(v.round()),
                  ),
                ),
              ),
              SizedBox(width: 44 * u, child: Text('$value$unit', textAlign: TextAlign.right, style: AppText.value.copyWith(fontSize: 11))),
            ],
          ),
        );

    Widget toggle(String label, String detail, bool value, void Function(bool v) onChanged) => Padding(
          padding: EdgeInsets.only(top: 4 * u),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: const TextStyle(fontSize: 12, color: AppColors.text1)),
                    Text(detail, style: const TextStyle(fontSize: 10, color: AppColors.text3)),
                  ],
                ),
              ),
              Switch(value: value, onChanged: onChanged),
            ],
          ),
        );

    return HudPanel(
      title: 'Ajustes del mando',
      icon: Icons.tune_rounded,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          slider('VELOCIDAD DEL CARRITO (= la de la app · L2+L3 / L2+R3)', pad.appState.speed, 0, 100, '%', pad.appState.setSpeed),
          slider('ZONA MUERTA', s.deadzone, 5, 30, '%', (v) => pad.update((x) => x.deadzone = v)),
          slider('VELOCIDAD BRAZO', s.armSpeed, 1, 8, '', (v) => pad.update((x) => x.armSpeed = v)),
          toggle('Invertir brazo arriba/abajo', 'Stick derecho como avión', s.invertArmY, (v) => pad.update((x) => x.invertArmY = v)),
          toggle('Vibración', 'Avisos al cambiar de modo, foto, paro', s.rumble, (v) => pad.update((x) => x.rumble = v)),
          toggle('Vibrar con el baile', 'El mando golpea al ritmo de cada paso y la luz destella', s.danceRumble, (v) => pad.update((x) => x.danceRumble = v)),
          toggle('Luz según el gas (EXPLORACIÓN)', 'MQ-2: verde < 20 %, amarillo 20–35 %, rojo > 35 % (vibra). Necesita la placa de sensores vinculada', s.gasLight, (v) => pad.update((x) => x.gasLight = v)),
          toggle('SPORT en azul y rojo', 'En SPORT la luz alterna azul y rojo, con cualquier color elegido', s.sportDuo, (v) => pad.update((x) => x.sportDuo = v)),
          toggle('Combos (L2 + botón)', 'Y el código ↑↑↓↓←→←→○✕ en el menú', s.combos, (v) => pad.update((x) => x.combos = v)),
          SizedBox(height: 8 * u),
          Text('LUZ DEL MANDO', style: AppText.label.copyWith(fontSize: 9)),
          SizedBox(height: 6 * u),
          Wrap(
            spacing: 6 * u,
            runSpacing: 6 * u,
            children: [
              for (final (k, label) in const [('fire', 'Fuego rojo'), ('mode', 'Rojo fijo por modo'), ('off', 'Apagada')])
                HudChip(text: label, active: s.light == k, onTap: () => pad.update((x) => x.light = k)),
              for (final (k, label, c) in const [
                ('c:00FF3C', 'Verde', Color(0xFF00FF3C)),
                ('c:FF0000', 'Rojo', Color(0xFFFF0000)),
                ('c:0050FF', 'Azul', Color(0xFF0050FF)),
                ('c:00E5FF', 'Cian', Color(0xFF00E5FF)),
                ('c:8C00FF', 'Morado', Color(0xFF8C00FF)),
                ('c:FF1E8C', 'Rosa', Color(0xFFFF1E8C)),
                ('c:FF9600', 'Ámbar', Color(0xFFFF9600)),
                ('c:FFFFFF', 'Blanco', Color(0xFFFFFFFF)),
              ])
                GestureDetector(
                  onTap: () => pad.update((x) => x.light = k),
                  child: Tooltip(
                    message: 'Fuego $label',
                    child: Container(
                      width: 26 * u,
                      height: 26 * u,
                      decoration: BoxDecoration(
                        color: c,
                        shape: BoxShape.circle,
                        border: Border.all(color: s.light == k ? AppColors.text1 : AppColors.line, width: s.light == k ? 2.5 : 1),
                      ),
                      child: s.light == k ? Icon(Icons.check_rounded, size: 15 * u, color: Colors.black) : null,
                    ),
                  ),
                ),
              HudChip(text: 'Probar', icon: Icons.lightbulb_outline_rounded, onTap: pad.connected ? pad.testLight : null),
            ],
          ),
          SizedBox(height: 4 * u),
          const Text('Por defecto: fuego rojo. Los círculos de color hacen fuego animado de ese color (más vivo en DANCE). EXPLORACIÓN sigue al MQ-2 y SPORT va en azul y rojo si está activado.',
              style: TextStyle(fontSize: 10, color: AppColors.text3)),
          if (!pad.lightSupported) ...[
            SizedBox(height: 6 * u),
            const Text('Este teléfono no deja cambiar la luz del mando (requiere Android 12+). Todo lo demás funciona.',
                style: TextStyle(fontSize: 10, color: AppColors.yellow)),
          ],
        ],
      ),
    );
  }
}

// =============================================================
//  Bitácora
// =============================================================

class _LogPanel extends StatelessWidget {
  final GamepadLink pad;
  const _LogPanel({required this.pad});

  @override
  Widget build(BuildContext context) {
    final u = context.u;
    String two(int n) => n.toString().padLeft(2, '0');
    return HudPanel(
      title: 'Bitácora del mando',
      icon: Icons.history_rounded,
      child: pad.log.isEmpty
          ? const Text('Aún no hay acciones.', style: TextStyle(fontSize: 11, color: AppColors.text3))
          : Column(
              children: [
                for (final a in pad.log)
                  Padding(
                    padding: EdgeInsets.symmetric(vertical: 3 * u),
                    child: Row(
                      children: [
                        Text('${two(a.time.hour)}:${two(a.time.minute)}:${two(a.time.second)}', style: AppText.label.copyWith(fontSize: 9.5)),
                        SizedBox(width: 10 * u),
                        Expanded(child: Text(a.text, style: const TextStyle(fontSize: 11.5, color: AppColors.text1), overflow: TextOverflow.ellipsis)),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }
}
