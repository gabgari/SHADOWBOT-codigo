import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_theme.dart';
import '../models/node_link.dart';
import '../services/device_config.dart';
import '../services/esp32_control_service.dart';
import '../state/app_state.dart';
import '../widgets/common.dart';
import '../widgets/top_bar.dart';

/// Pantalla donde se completa la vinculación pendiente de los tres nodos
/// de hardware. Guarda el host/IP en `DeviceConfig` y prueba la conexión
/// llamando al endpoint correspondiente de cada servicio en `services/`.
class ConexionesScreen extends StatelessWidget {
  const ConexionesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final config = context.watch<DeviceConfig>();

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            ScreenTopBar(title: 'Conexiones', onBack: () => Navigator.of(context).pop()),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                children: [
                  const Text(
                    'Vincula cada nodo escribiendo su IP en la red local. Puedes dejar cualquiera sin vincular — usa solo los que tengas armados. Mientras no vinculas nada, los 4 LEDs del carrito (físicos, en la ESP32 de sensores) corren solos en un barrido; cada nodo que vincules apaga su LED para confirmarlo.',
                    style: TextStyle(fontSize: 12.5, color: AppColors.text2, fontWeight: FontWeight.w500),
                  ),
                  const SectionTitle('CAM 1 · ESP32-CAM (video)'),
                  _ConnectionCard(
                    node: config.of(HardwareNode.esp32cam),
                    hint: '192.168.1.50',
                    helper: 'Usa la IP que el firmware imprime por Serial o envía por Telegram (/ip). Endpoints: /viewer, /stream, /capture. Al vincular, se apaga el LED 1 del barrido.',
                  ),
                  const SectionTitle('ESP32-S3 · Control de motores'),
                  _ConnectionCard(
                    node: config.of(HardwareNode.esp32s3Control),
                    hint: '192.168.1.51',
                    helper: 'Firmware pendiente de programar (BTS7960). La app ya sabe llamar a /move y /ping en cuanto exista. Al vincular, se apaga el LED 2 del barrido.',
                  ),
                  const SizedBox(height: 10),
                  const _MotorInvertCard(),
                  const SectionTitle('ESP32 · Sensores + LEDs'),
                  _ConnectionCard(
                    node: config.of(HardwareNode.esp32Sensors),
                    hint: '192.168.1.52',
                    helper: 'Firmware pendiente de programar (MQ-2 + 4 LEDs). La app espera JSON en GET /sensors y usa GET /led. Al vincular, se apaga el LED 3 del barrido.',
                  ),
                  const SectionTitle('CAM 2 · Tapo C110 (RTSP)'),
                  _ConnectionCard(
                    node: config.of(HardwareNode.tapoCam),
                    hint: 'rtsp://usuario:clave@192.168.1.53:554/stream1',
                    helper: 'Pega la URL RTSP completa (con usuario y clave de "Cuenta de cámara" configurados en la app Tapo). /stream1 = HD, /stream2 = SD. Al vincular el video, se apaga el LED 4 del barrido.',
                    fieldHeight: 3,
                  ),
                  const SectionTitle('Iniciar'),
                  const _StartCard(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Botón final del flujo de vinculación. No importa si el usuario dejó
/// algún nodo sin IP (o todos) — "Iniciar" siempre procede con lo que haya:
/// detiene el barrido "auto increíble" de los LEDs, los hace parpadear 2
/// veces juntos como confirmación y desbloquea el control real del carrito
/// (antes de esto, D-pad, brazo y LEDs manuales no hacen nada — ver
/// `AppState.controlLocked`), y manda al usuario a la pantalla de Control.
class _StartCard extends StatefulWidget {
  const _StartCard();

  @override
  State<_StartCard> createState() => _StartCardState();
}

class _StartCardState extends State<_StartCard> {
  bool _starting = false;

  Future<void> _start() async {
    final state = context.read<AppState>();
    setState(() => _starting = true);
    await state.startSystem();
    if (!mounted) return;
    state.showScreen(ScreenNames.control);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Hasta que no presiones este botón, el carrito está bloqueado: motores, brazo y LEDs no responden desde la app, aunque los toques. Iniciar funciona con los nodos que hayas vinculado, sean todos, algunos o ninguno.',
            style: TextStyle(fontSize: 11.5, color: AppColors.text3),
          ),
          const SizedBox(height: 12),
          PrimaryButton(
            label: _starting ? 'Iniciando…' : 'Iniciar',
            icon: Icons.play_arrow_rounded,
            onPressed: _starting ? null : _start,
          ),
        ],
      ),
    );
  }
}

/// Corrige el sentido de giro de un motor (cableado espejado) sin volver a
/// flashear: llama a `GET /motorinvert` del ESP32-S3 de control, que
/// guarda el valor en NVS. Vive pegada a la tarjeta de conexión de ese
/// nodo porque no tiene sentido sin él.
class _MotorInvertCard extends StatefulWidget {
  const _MotorInvertCard();

  @override
  State<_MotorInvertCard> createState() => _MotorInvertCardState();
}

class _MotorInvertCardState extends State<_MotorInvertCard> {
  bool? _aInverted;
  bool? _bInverted;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  Esp32ControlService get _service => context.read<AppState>().controlService;

  Future<void> _refresh() async {
    if (!mounted || !_service.isConfigured) return;
    setState(() => _loading = true);
    final result = await _service.getMotorInvert();
    if (!mounted) return;
    setState(() {
      _loading = false;
      _aInverted = result?.aInverted;
      _bInverted = result?.bInverted;
    });
  }

  Future<void> _setInvert({bool? a, bool? b}) async {
    setState(() {
      if (a != null) _aInverted = a;
      if (b != null) _bInverted = b;
    });
    final ok = await _service.setMotorInvert(a: a, b: b);
    if (!mounted) return;
    if (!ok) {
      showAppToast(context, 'No se pudo cambiar — revisa que el ESP32-S3 esté vinculado');
      await _refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final configured = context.watch<AppState>().controlService.isConfigured;

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text('Dirección de motores', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: AppColors.text1)),
              ),
              if (_loading)
                const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.orange))
              else
                IconButton(
                  icon: const Icon(Icons.refresh_rounded, size: 18, color: AppColors.text3),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  onPressed: configured ? _refresh : null,
                ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            configured
                ? 'Si al mover el carrito una rueda gira al revés, invierte SOLO ese motor aquí — se guarda en la ESP32, sin volver a flashear.'
                : 'Vincula el ESP32-S3 de arriba para poder cambiar esto.',
            style: const TextStyle(fontSize: 10.5, color: AppColors.text3),
          ),
          const SizedBox(height: 4),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('Intercambiar izquierda ↔ derecha', style: TextStyle(fontSize: 13, color: AppColors.text1)),
            subtitle: const Text('Si avanza y retrocede bien pero gira al revés. Se guarda en el teléfono (no hay que flashear).',
                style: TextStyle(fontSize: 10, color: AppColors.text3)),
            value: context.watch<AppState>().swapSides,
            activeThumbColor: AppColors.orange,
            onChanged: (v) => context.read<AppState>().setSwapSides(v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('Motor izquierdo invertido', style: TextStyle(fontSize: 13, color: AppColors.text1)),
            value: _aInverted ?? false,
            activeThumbColor: AppColors.orange,
            onChanged: configured ? (v) => _setInvert(a: v) : null,
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('Motor derecho invertido', style: TextStyle(fontSize: 13, color: AppColors.text1)),
            value: _bInverted ?? false,
            activeThumbColor: AppColors.orange,
            onChanged: configured ? (v) => _setInvert(b: v) : null,
          ),
        ],
      ),
    );
  }
}

class _ConnectionCard extends StatefulWidget {
  final NodeLink node;
  final String hint;
  final String helper;
  final int fieldHeight;
  const _ConnectionCard({required this.node, required this.hint, required this.helper, this.fieldHeight = 1});

  @override
  State<_ConnectionCard> createState() => _ConnectionCardState();
}

class _ConnectionCardState extends State<_ConnectionCard> {
  late final TextEditingController _controller = TextEditingController(text: widget.node.host);
  late String _shownHost = widget.node.host;
  bool _testing = false;
  bool _searching = false;

  /// La app pudo cambiar la IP sola (anuncio de la placa, Tapo encontrada en
  /// la red): si el usuario no estaba escribiendo otra cosa, el campo se
  /// actualiza — si no, "Probar conexión" volvería a guardar la IP vieja.
  void _syncFromConfig() {
    final host = widget.node.host;
    if (host == _shownHost) return;
    if (_controller.text.trim() == _shownHost.trim()) _controller.text = host;
    _shownHost = host;
  }

  Future<void> _findTapo() async {
    setState(() => _searching = true);
    final msg = await context.read<AppState>().findTapoNow();
    if (!mounted) return;
    setState(() => _searching = false);
    showAppToast(context, msg);
  }

  Future<void> _testConnection() async {
    final state = context.read<AppState>();
    final config = context.read<DeviceConfig>();
    final host = _controller.text;
    await config.setHost(widget.node.node, host);
    _shownHost = widget.node.host;
    if (!mounted) return;

    if (host.trim().isEmpty) {
      showAppToast(context, 'Escribe una IP antes de probar la conexión');
      return;
    }

    setState(() => _testing = true);
    config.setStatus(widget.node.node, LinkStatus.connecting);

    bool ok = false;
    String? camWarning;
    switch (widget.node.node) {
      case HardwareNode.esp32cam:
        final st = await state.camService.getStatus();
        ok = st != null;
        if (st != null && !st.cam) {
          // La placa está en la red pero el sensor no arrancó: no es la IP.
          camWarning = 'La CAM responde, pero la CÁMARA no inició (error ${st.err}). '
              'Revisa el flex de la cámara${st.psram ? '' : ' y activa PSRAM "OPI PSRAM" al cargar el código'}.';
        }
        break;
      case HardwareNode.esp32s3Control:
        ok = await state.controlService.ping();
        break;
      case HardwareNode.esp32Sensors:
        ok = await state.sensorService.poll() != null;
        break;
      case HardwareNode.tapoCam:
        ok = await state.tapoCamService.checkReachable();
        break;
    }

    if (!mounted) return;
    setState(() => _testing = false);
    config.setStatus(widget.node.node, ok ? LinkStatus.online : LinkStatus.error);
    if (ok && camWarning != null) {
      state.addAlert(AppColors.yellow, camWarning);
      showAppToast(context, camWarning);
    } else if (ok) {
      state.addAlert(AppColors.green, '${widget.node.label} vinculado correctamente');
      showAppToast(context, '${widget.node.label} vinculado');
    } else {
      showAppToast(context, 'Sin respuesta de ${widget.node.label} — revisa la IP y que el firmware esté cargado');
    }
  }

  @override
  Widget build(BuildContext context) {
    _syncFromConfig();
    final color = switch (widget.node.status) {
      LinkStatus.online => AppColors.green,
      LinkStatus.connecting => AppColors.yellow,
      LinkStatus.error => AppColors.red,
      LinkStatus.pending => AppColors.text3,
    };

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(width: 7, height: 7, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
              const SizedBox(width: 6),
              Text(widget.node.statusLabel, style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: color)),
            ],
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _controller,
            style: const TextStyle(color: AppColors.text1, fontSize: 13.5),
            keyboardType: TextInputType.text,
            maxLines: widget.fieldHeight,
            autocorrect: false,
            enableSuggestions: false,
            // El corrector ortográfico nativo de Android se activa solo en
            // cualquier TextField que no lo desactive — en una IP (no es
            // una palabra real) algunos teclados (Samsung, SwiftKey) lo
            // marcan mal y el subrayado de corrección llega a bloquear la
            // escritura. Se apaga porque acá nunca hace falta.
            spellCheckConfiguration: const SpellCheckConfiguration.disabled(),
            decoration: InputDecoration(
              hintText: widget.hint,
              hintStyle: const TextStyle(color: AppColors.text3),
              filled: true,
              fillColor: AppColors.surface2,
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: AppColors.line)),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: AppColors.line)),
              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: AppColors.orange)),
            ),
          ),
          const SizedBox(height: 6),
          Text(widget.helper, style: const TextStyle(fontSize: 10.5, color: AppColors.text3)),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: _testing ? null : _testConnection,
              style: OutlinedButton.styleFrom(
                backgroundColor: AppColors.surface2,
                foregroundColor: AppColors.text1,
                side: const BorderSide(color: AppColors.line),
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: _testing
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.orange))
                  : const Text('Probar conexión', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
            ),
          ),
          if (widget.node.node == HardwareNode.tapoCam) ...[
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _searching || _testing ? null : _findTapo,
                icon: _searching
                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.radar_rounded, size: 16),
                label: Text(_searching ? 'Buscando en la red…' : 'Buscar la Tapo en la red (otra red / hotspot)',
                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12.5)),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.text1,
                  side: const BorderSide(color: AppColors.line),
                  padding: const EdgeInsets.symmetric(vertical: 11),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ),
            const SizedBox(height: 4),
            const Text('Cambia solo la IP de la URL (mismo usuario, clave y stream). La app también lo hace sola si el video no arranca.',
                style: TextStyle(fontSize: 10, color: AppColors.text3)),
          ],
        ],
      ),
    );
  }
}
