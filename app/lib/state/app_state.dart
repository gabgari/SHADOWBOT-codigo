import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_theme.dart';
import '../models/app_models.dart';
import '../models/node_link.dart';
import '../services/device_config.dart';
import '../services/esp32_cam_service.dart';
import '../services/esp32_control_service.dart';
import '../services/esp32_sensor_service.dart';
import '../services/tapo_cam_service.dart';
import '../services/vision_discovery/vision_discovery.dart';
import '../services/vision_service.dart';
import '../widgets/camera_filters.dart';
import 'media_library.dart';

/// Identifica una de las 2 cámaras (ESP32-CAM o Tapo C110). Se reutiliza
/// para dos selecciones independientes que el usuario hace desde la
/// pantalla Cámara: de cuál toma el frame el asistente de IA (botón
/// "Analizar" / preguntas por voz como "¿qué ves?", ver
/// [AppState.aiCameraSource]) y cuál se muestra como vista principal en
/// Control y usan por defecto los atajos de foto/video (ver
/// [AppState.primaryCamera]). Por defecto ambas siguen siendo el ESP32-CAM
/// (comportamiento previo, sin cambios si nunca se vincula la Tapo).
enum AiCameraSource { esp32cam, tapoCam }

/// Nombres de pantalla, equivalentes a los `data-screen` del prototipo.
class ScreenNames {
  static const inicio = 'inicio';
  static const nodos = 'nodos';
  static const control = 'control';
  static const sensores = 'sensores';
  static const sistema = 'sistema';
  static const camara = 'camara';
  static const galeria = 'galeria'; // sección Multimedia
  static const alertas = 'alertas';
  static const mando = 'mando';
}

/// Estado global de la app: navegación, control del carrito, sensores,
/// alertas y galería. Es el equivalente al IIFE `<script>` del
/// prototipo `index.html`, pero repartido en un `ChangeNotifier` de Flutter.
///
/// Todo lo que en el HTML original era `setInterval` con `Math.random()`
/// (telemetría, gas, batería) se mantiene aquí como
/// **modo demostración**: se usa siempre que el nodo de hardware
/// correspondiente todavía no esté vinculado (ver `DeviceConfig`).
class AppState extends ChangeNotifier {
  final DeviceConfig deviceConfig;
  late final Esp32CamService camService;
  late final Esp32ControlService controlService;
  late final Esp32SensorService sensorService;
  late final TapoCamService tapoCamService;

  /// PC de VISIÓN IA (YOLO sobre CAM 2). Opcional: sin ella, CAM 2 es RTSP.
  late final VisionService vision;
  late final MediaLibrary media;

  AppState({required this.deviceConfig}) {
    camService = Esp32CamService(deviceConfig);
    controlService = Esp32ControlService(deviceConfig);
    sensorService = Esp32SensorService(deviceConfig);
    tapoCamService = TapoCamService(deviceConfig);
    vision = VisionService();
    media = MediaLibrary(
      camService: camService,
      tapoCam: tapoCamService,
      vision: vision,
      filterOf: filterOf,
      onEvent: (ok, text) => addAlert(ok ? AppColors.green : AppColors.yellow, text),
    );
    // Cada vez que cambia el estado de vinculación de un nodo (host nuevo,
    // ping ok/error), refleja ese estado en los LEDs físicos de la ESP32 de
    // sensores — ver [_syncStatusLeds].
    deviceConfig.addListener(_syncStatusLeds);
    // Y le pasa a esa misma ESP32 la IP de CONTROL, que es a donde el mando
    // de PS4 manda motores/brazo — ver [_syncControlIpToSensors].
    deviceConfig.addListener(_syncControlIpToSensors);
    // Tras "Iniciar", mantiene encendida la pantalla circular de CONTROL
    // (también si esa placa se reinicia) — ver [_syncDisplayToControl].
    deviceConfig.addListener(_syncDisplayToControl);
    // La PC de visión sabe dónde está la Tapo: si cambia de IP (otra red,
    // hotspot del celular) se corrige sola la URL RTSP de CAM 2.
    vision.addListener(_syncTapoIpFromVision);
    _boards = BoardDiscovery(onFound: _onBoardAnnounce);
  }

  // ---------------- IPs automáticas de las placas ----------------
  // CONTROL y SENSORES gritan su IP por UDP (4210) cada 3 s: la app la
  // toma sola (en casa o con el hotspot del celular), sin escribirla.
  late final BoardDiscovery _boards;

  void _onBoardAnnounce(String board, String ip, String? controlIp) {
    void apply(HardwareNode node, String newIp, String name) {
      final link = deviceConfig.of(node);
      if (link.host == newIp) return;
      deviceConfig.setHost(node, newIp).then((_) => pingNode(node));
      addAlert(AppColors.green, '$name encontrado solo en $newIp', category: 'sistema');
    }

    if (board == 'control') apply(HardwareNode.esp32s3Control, ip, 'CONTROL');
    if (board == 'sensores') {
      apply(HardwareNode.esp32Sensors, ip, 'SENSORES');
      // SENSORES también sabe la IP de CONTROL (por si su anuncio no llega).
      if (controlIp != null && deviceConfig.of(HardwareNode.esp32s3Control).host.isEmpty) {
        apply(HardwareNode.esp32s3Control, controlIp, 'CONTROL');
      }
    }
  }

  /// La PC de visión dice dónde está la Tapo. Solo se usa como AYUDA:
  /// únicamente cuando la PC la está viendo de verdad, solo cuando esa IP
  /// cambia (no se re-aplica en cada aviso, así nunca pisa lo que el usuario
  /// escribió a mano) y nunca si el RTSP ya se está viendo bien.
  String? _visionCamIpApplied;

  void _syncTapoIpFromVision() {
    final camIp = vision.cameraIp;
    if (!vision.available || camIp == null || camIp.isEmpty || camIp == _visionCamIpApplied) return;
    _visionCamIpApplied = camIp;
    if (tapoCamService.isPlaying) return;
    _applyTapoUrl(camIp, 'la encontró la PC de visión');
  }

  void _applyTapoUrl(String ip, String why) {
    final uri = Uri.tryParse(deviceConfig.of(HardwareNode.tapoCam).host);
    if (uri == null || uri.scheme != 'rtsp' || uri.host.isEmpty || uri.host == ip) return;
    deviceConfig.setHost(HardwareNode.tapoCam, uri.replace(host: ip).toString());
    addAlert(AppColors.green, 'CAM 2 (Tapo): nueva IP $ip ($why)', category: 'sistema');
  }

  // ---------------- La Tapo cambió de IP: buscarla sola ----------------
  // Funciona SIN la PC de visión. Si el RTSP no arranca (error o ~12 s sin
  // video), se busca en la red un equipo con el puerto 554 y se cambia solo
  // la IP de la URL (mismo usuario / clave / stream). Como mucho una
  // búsqueda cada 30 s; las IPs que ya fallaron no se repiten.
  final Set<String> _tapoTried = {};

  Future<String> findTapoNow() async {
    final r = await tapoCamService.findOnLan(exclude: _tapoTried);
    final url = r.url;
    if (url == null) return r.message;
    _tapoTried.add(Uri.tryParse(deviceConfig.of(HardwareNode.tapoCam).host)?.host ?? '');
    _applyTapoUrl(Uri.parse(url).host, 'encontrada en la red');
    return r.message;
  }

  void _autoFindTapo() {
    final tapo = tapoCamService;
    if (!tapo.isConfigured || tapo.isPlaying || tapo.searching) {
      if (tapo.isPlaying) _tapoTried.clear();
      return;
    }
    final attempt = tapo.lastAttempt;
    if (attempt == null) return; // nadie ha pedido ver la Tapo todavía
    final stuck = tapo.lastError != null || DateTime.now().difference(attempt) > const Duration(seconds: 12);
    if (!stuck || DateTime.now().difference(tapo.lastSearch) < const Duration(seconds: 30)) return;
    findTapoNow();
  }

  AiCameraSource aiCameraSource = AiCameraSource.esp32cam;
  void setAiCameraSource(AiCameraSource source) {
    aiCameraSource = source;
    notifyListeners();
  }

  // ---------------- Cámara principal ----------------
  // Cuál de las 2 cámaras se muestra en el visor grande de Control y de
  // cuál capturan por defecto los atajos de foto/video que no especifican
  // cámara (p.ej. el comando de voz "toma una foto"). Se persiste porque,
  // a diferencia de `aiCameraSource`, es una preferencia de "cómo quiero
  // ver mi carrito" que tiene sentido que sobreviva a cerrar la app.
  static const _keyPrimaryCamera = 'primary_camera';
  AiCameraSource primaryCamera = AiCameraSource.esp32cam;

  Future<void> _loadPrimaryCamera() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getString(_keyPrimaryCamera) == 'tapoCam') {
      primaryCamera = AiCameraSource.tapoCam;
      notifyListeners();
    }
  }

  Future<void> setPrimaryCamera(AiCameraSource source) async {
    primaryCamera = source;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyPrimaryCamera, source.name);
  }

  final _rnd = Random();
  Timer? _demoTimer;
  Timer? _healthTimer;
  final Set<HardwareNode> _pinging = {};

  // ---------------- Navegación ----------------
  String currentScreen = ScreenNames.control;
  void showScreen(String name) {
    currentScreen = name;
    notifyListeners();
  }

  // ---------------- Telemetría real de nodos (latencia) ----------------
  // Nada de esto se simula: cada ping abre una conexión HTTP real al nodo
  // y `Stopwatch` mide el tiempo real de ida y vuelta. Si el nodo no está
  // configurado o no responde, el resultado es `null`/offline — nunca se
  // inventa un valor.

  /// Hace un ping real a [node] y guarda estado + latencia medida en
  /// [deviceConfig]. Se puede llamar a demanda (botón "Probar conexión")
  /// o desde el timer periódico de abajo.
  Future<void> pingNode(HardwareNode node) async {
    final link = deviceConfig.of(node);
    if (link.host.isEmpty) {
      deviceConfig.reportPing(node, ok: false);
      return;
    }
    if (_pinging.contains(node)) return; // ya hay un ping en curso a este nodo
    _pinging.add(node);
    final sw = Stopwatch()..start();
    bool ok;
    try {
      switch (node) {
        case HardwareNode.esp32cam:
          ok = await camService.checkReachable();
          break;
        case HardwareNode.esp32s3Control:
          ok = await controlService.ping();
          break;
        case HardwareNode.esp32Sensors:
          ok = await sensorService.poll() != null;
          break;
        case HardwareNode.tapoCam:
          ok = await tapoCamService.checkReachable();
          break;
      }
    } catch (_) {
      ok = false;
    }
    sw.stop();
    _pinging.remove(node);
    deviceConfig.reportPing(node, ok: ok, latencyMs: ok ? sw.elapsedMilliseconds : null);
  }

  void _startHealthTimer() {
    _healthTimer ??= Timer.periodic(const Duration(seconds: 5), (_) {
      for (final node in HardwareNode.values) {
        // La Tapo queda fuera de este ping automático a propósito: a
        // diferencia de los otros 3 (una petición HTTP liviana), "probar"
        // la Tapo implica abrir el stream RTSP completo — si se hiciera
        // cada 5s en segundo plano, la cámara quedaría transmitiendo todo
        // el tiempo (datos/batería) por el solo hecho de tener la URL
        // guardada, sin que el usuario esté viendo nada. Su conexión se
        // abre solo cuando de verdad hace falta: al entrar a Cámara, al
        // pedirle a la IA que la analice, o al tocar "Probar conexión".
        if (node == HardwareNode.tapoCam) continue;
        if (deviceConfig.of(node).host.isNotEmpty) pingNode(node);
      }
      _autoFindTapo();
    });
  }

  // ---------------- Control / estado del carrito ----------------
  static const Map<String, String> stateMessages = {
    'adelante': 'Moviendo adelante',
    'atras': 'Moviendo hacia atrás',
    'izquierda': 'Desplazamiento lateral izquierdo',
    'derecha': 'Desplazamiento lateral derecho',
    'diag-izq': 'Moviendo en diagonal izquierda',
    'diag-der': 'Moviendo en diagonal derecha',
    'giro-izq': 'Girando sobre su eje — izquierda',
    'giro-der': 'Girando sobre su eje — derecha',
    'detener': 'Vehículo detenido',
  };

  String pressedMove = '';
  String stateValue = 'Vehículo detenido';
  /// Velocidad de manejo (0-100 %). La respetan la consola, la pantalla
  /// completa, la voz Y el mando (GamepadLink la usa como tope del stick;
  /// L2+L3 / L2+R3 la cambian aquí). Se guarda en el teléfono.
  static const _keySpeed = 'drive_speed';
  int speed = 60;
  Timer? _speedSave;

  void setSpeed(int v) {
    speed = v.clamp(0, 100);
    notifyListeners();
    _speedSave?.cancel();
    _speedSave = Timer(const Duration(milliseconds: 400), () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_keySpeed, speed);
    });
  }

  /// Rumbo ESTIMADO para la brújula de la consola (sin sensor: solo suma
  /// los giros que se mandan).
  double heading = 0; // grados

  // ---------------- Manejo con joystick (mantener presionado) ----------------
  // El firmware frena solo si no recibe un /move en 800 ms (watchdog). El
  // joystick de la consola manda la dirección al tocar y la repite cada
  // 300 ms mientras el dedo siga abajo; al soltar manda "detener".
  Timer? _holdTimer;
  String? _heldMove;

  void holdMove(String move) {
    if (controlLocked || move == _heldMove) return;
    _heldMove = move;
    _holdTimer?.cancel();
    pressMove(move);
    _holdTimer = Timer.periodic(const Duration(milliseconds: 300), (_) {
      final m = _heldMove;
      if (m != null) _sendMove(m);
    });
  }

  void releaseMove() {
    _holdTimer?.cancel();
    _holdTimer = null;
    if (_heldMove == null) return;
    _heldMove = null;
    pressMove('detener');
  }

  // ---------------- Gadgets de EXPLORACIÓN (como en el mando) ----------------

  /// Retroceso corto (0.6 s), igual que "Share" en el mando.
  Future<void> shortRetreat() async {
    if (controlLocked) return;
    releaseMove();
    holdMove('atras');
    await Future.delayed(const Duration(milliseconds: 600));
    if (_heldMove == 'atras') releaseMove();
  }

  /// Escaneo panorámico con el brazo (L3 en el mando): barre a la
  /// izquierda, a la derecha y vuelve al centro.
  bool scanning = false;
  Future<void> armScan() async {
    if (controlLocked || scanning) return;
    scanning = true;
    notifyListeners();
    try {
      setArmAngles(armPan, armHomeTilt);
      for (final target in [10, 90, armHomePan]) {
        while (armPan != target) {
          final step = (target - armPan).clamp(-3, 3);
          setArmAngles(armPan + step, armTilt);
          await Future.delayed(const Duration(milliseconds: 60));
          if (!scanning) return;
        }
        await Future.delayed(const Duration(milliseconds: 250));
      }
    } finally {
      scanning = false;
      notifyListeners();
    }
  }

  /// Paro total: frena motores y corta cualquier repetición del joystick.
  void emergencyStop() {
    scanning = false;
    _holdTimer?.cancel();
    _holdTimer = null;
    _heldMove = null;
    pressMove('detener');
    addAlert(AppColors.red, 'PARO DE EMERGENCIA', category: 'sistema');
  }

  /// Envía un movimiento. Si el ESP32-S3 de control está vinculado,
  /// se le manda el comando real; si no, solo se refleja en la UI
  /// (estado) como demostración — ver `Esp32ControlService`.
  Future<void> pressMove(String move) async {
    if (controlLocked) return;
    pressedMove = move;
    stateValue = stateMessages[move] ?? '—';
    if (move == 'giro-izq') heading -= 30;
    if (move == 'giro-der') heading += 30;
    notifyListeners();

    await _sendMove(move);
  }

  Future<void> _sendMove(String move) async {
    final node = deviceConfig.of(HardwareNode.esp32s3Control);
    if (node.host.isNotEmpty) {
      MoveCommand? cmd;
      for (final c in MoveCommand.values) {
        if (c.wireValue == move) {
          cmd = c;
          break;
        }
      }
      if (cmd != null) {
        final sw = Stopwatch()..start();
        final ok = await controlService.sendMove(cmd, speed);
        sw.stop();
        deviceConfig.reportPing(HardwareNode.esp32s3Control, ok: ok, latencyMs: ok ? sw.elapsedMilliseconds : null);
      }
    }
  }

  // ---------------- Control del brazo (cámara, 2 ejes) ----------------
  static const Map<String, String> armStateMessages = {
    'arriba': 'Brazo — inclinando arriba',
    'abajo': 'Brazo — inclinando abajo',
    'izquierda': 'Brazo — girando izquierda',
    'derecha': 'Brazo — girando derecha',
    'arriba-izq': 'Brazo — diagonal arriba izquierda',
    'arriba-der': 'Brazo — diagonal arriba derecha',
    'abajo-izq': 'Brazo — diagonal abajo izquierda',
    'abajo-der': 'Brazo — diagonal abajo derecha',
    'centro': 'Brazo centrado',
  };

  String pressedArm = '';
  String armStateValue = 'Brazo centrado';

  // ---------------- Brazo por sliders (posición absoluta) ----------------
  // 0-100%, se manda como 0-180° (ver Esp32ControlService.sendArmAngles).
  // 50/50 = centrado. Al arrastrar el slider se dispara un evento por
  // cada pixel — se manda con un pequeño throttle para no saturar la
  // ESP32 ni la red; el valor en pantalla se actualiza siempre al toque.
  int armPan = 50;
  int armTilt = 50;
  Timer? _armThrottle;
  int _pendingPan = 50, _pendingTilt = 50;

  void setArmAngles(int panPercent, int tiltPercent) {
    if (controlLocked) return;
    armPan = panPercent.clamp(0, 100);
    armTilt = tiltPercent.clamp(0, 100);
    notifyListeners();

    _pendingPan = armPan;
    _pendingTilt = armTilt;
    _armThrottle ??= Timer(const Duration(milliseconds: 90), () {
      _armThrottle = null;
      _sendArmAngles(_pendingPan, _pendingTilt);
    });
  }

  /// Lleva el brazo a su posición 0 (la que el usuario fijó; 50/50 de fábrica).
  void centerArm() => setArmAngles(armHomePan, armHomeTilt);

  // ---------------- Brazo con el stick del mando ----------------
  // El mando lleva su propia posición en grados con decimales y la manda
  // ~20 veces por segundo (una petición a la vez), así la ESP32 recibe pasos
  // chicos y parejos y sus servos suaves no frenan/arrancan entre paso y
  // paso. armPan/armTilt (0-100) se actualizan solo para la pantalla.
  bool _padArmBusy = false;
  int? _padArmPendingPan, _padArmPendingTilt;

  void setArmDegreesFromPad(double panDeg, double tiltDeg) {
    if (controlLocked) return;
    final pan = panDeg.round().clamp(0, 180);
    final tilt = tiltDeg.round().clamp(0, 180);
    final pp = (pan * 100 / 180).round(), tp = (tilt * 100 / 180).round();
    if (pp != armPan || tp != armTilt) {
      armPan = pp;
      armTilt = tp;
      notifyListeners();
    }
    _padArmPendingPan = pan;
    _padArmPendingTilt = tilt;
    if (!_padArmBusy) _flushPadArm();
  }

  int? _padArmLastPan, _padArmLastTilt;

  Future<void> _flushPadArm() async {
    final pan = _padArmPendingPan, tilt = _padArmPendingTilt;
    if (pan == null || tilt == null || (pan == _padArmLastPan && tilt == _padArmLastTilt)) return;
    _padArmBusy = true;
    _padArmLastPan = pan;
    _padArmLastTilt = tilt;
    await controlService.sendArmAngles(pan, tilt);
    _padArmBusy = false;
    _flushPadArm(); // si el stick siguió moviéndose mientras tanto
  }

  // ---------------- Posición 0 del brazo ----------------
  // Dónde queda "centrado" el brazo de la cámara. Los servos casi nunca
  // quedan derechos a 90°: el usuario lo acomoda donde se ve recto y lo fija
  // (botón FIJAR 0 de la consola). Se guarda en el teléfono; centrar (botón,
  // R3, L2+←, voz) y el escaneo panorámico vuelven aquí.
  static const _keyArmHome = 'arm_home';
  int armHomePan = 50;
  int armHomeTilt = 50;

  Future<void> setArmHome() async {
    armHomePan = armPan;
    armHomeTilt = armTilt;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyArmHome, '$armHomePan,$armHomeTilt');
  }

  Future<void> resetArmHome() async {
    armHomePan = 50;
    armHomeTilt = 50;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyArmHome);
  }

  // ---------------- Lados de los motores ----------------
  static const _keySwapSides = 'motor_swap_sides';
  bool get swapSides => controlService.swapSides;

  Future<void> setSwapSides(bool v) async {
    controlService.swapSides = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keySwapSides, v);
  }

  // ---------------- Calibración de los BTS7960 ----------------
  // % de cada motor (ver Esp32ControlService.trimL/trimR). Se guarda en el
  // teléfono y queda como "de fábrica" para todo lo que mueve las ruedas.
  static const _keyTrim = 'motor_trim';
  int get trimL => controlService.trimL;
  int get trimR => controlService.trimR;

  Future<void> setMotorTrim({int? left, int? right}) async {
    if (left != null) controlService.trimL = left.clamp(30, 100);
    if (right != null) controlService.trimR = right.clamp(30, 100);
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyTrim, '${controlService.trimL},${controlService.trimR}');
  }

  /// Avanza [ms] a la velocidad actual, para ver si va derecho.
  Future<void> testDriveStraight({int ms = 2000}) async {
    if (controlLocked) return;
    releaseMove();
    holdMove('adelante');
    await Future.delayed(Duration(milliseconds: ms));
    if (_heldMove == 'adelante') releaseMove();
  }

  // ---------------- Servo de la base (PAN) invertido ----------------
  // Al cambiarlo se reflejan también la posición 0 y las A/B/C guardadas
  // (p → 100-p), para que sigan apuntando al mismo lugar físico.
  static const _keyInvertPan = 'arm_invert_pan';
  bool get invertPan => controlService.invertPan;

  Future<void> setInvertPan(bool v) async {
    if (v == controlService.invertPan) return;
    controlService.invertPan = v;
    await _mirrorStoredPan();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyInvertPan, v);
  }

  Future<void> _mirrorStoredPan() async {
    final prefs = await SharedPreferences.getInstance();
    armPan = 100 - armPan;
    armHomePan = 100 - armHomePan;
    if (prefs.containsKey(_keyArmHome)) await prefs.setString(_keyArmHome, '$armHomePan,$armHomeTilt');
    for (var i = 0; i < 3; i++) {
      final p = armPresets[i];
      if (p == null) continue;
      armPresets[i] = ArmPreset(pan: 100 - p.pan, tilt: p.tilt);
      await prefs.setString(_armPresetKeys[i], '${100 - p.pan},${p.tilt}');
    }
    notifyListeners();
  }

  /// Paso fino del brazo (botones TILT ↑↓ / PAN ←→ de la consola).
  void nudgeArm({int pan = 0, int tilt = 0}) => setArmAngles(armPan + pan, armTilt + tilt);

  // ---------------- Posiciones guardadas del brazo (A/B/C) ----------------
  // Hasta 3 posiciones, persistidas en el teléfono (sobreviven a cerrar la
  // app). Interacción tipo "preset de radio": tocar un slot vacío lo
  // guarda con la posición actual; tocar uno lleno mueve el brazo ahí;
  // mantener presionado uno lleno lo regraba con la posición actual.
  static const _armPresetKeys = ['arm_preset_a', 'arm_preset_b', 'arm_preset_c'];
  final List<ArmPreset?> armPresets = List<ArmPreset?>.filled(3, null);

  Future<void> loadArmPresets() async {
    final prefs = await SharedPreferences.getInstance();
    controlService.swapSides = prefs.getBool(_keySwapSides) ?? true;
    final trim = prefs.getString(_keyTrim)?.split(',');
    if (trim != null && trim.length == 2) {
      controlService.trimL = (int.tryParse(trim[0]) ?? 100).clamp(30, 100);
      controlService.trimR = (int.tryParse(trim[1]) ?? 100).clamp(30, 100);
    }
    final home = prefs.getString(_keyArmHome)?.split(',');
    if (home != null && home.length == 2) {
      armHomePan = int.tryParse(home[0]) ?? 50;
      armHomeTilt = int.tryParse(home[1]) ?? 50;
    }
    for (var i = 0; i < 3; i++) {
      final raw = prefs.getString(_armPresetKeys[i]);
      if (raw == null) continue;
      final parts = raw.split(',');
      if (parts.length == 2) {
        final pan = int.tryParse(parts[0]);
        final tilt = int.tryParse(parts[1]);
        if (pan != null && tilt != null) armPresets[i] = ArmPreset(pan: pan, tilt: tilt);
      }
    }
    // Primera vez con la base invertida (default): lo guardado se fijó con
    // el servo sin invertir, se refleja una sola vez.
    final invert = prefs.getBool(_keyInvertPan);
    controlService.invertPan = invert ?? true;
    if (invert == null) {
      await _mirrorStoredPan();
      await prefs.setBool(_keyInvertPan, true);
    }
    notifyListeners();
  }

  /// Guarda la posición actual del brazo en el slot [i] (0=A, 1=B, 2=C).
  Future<void> saveArmPreset(int i) async {
    armPresets[i] = ArmPreset(pan: armPan, tilt: armTilt);
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_armPresetKeys[i], '$armPan,$armTilt');
  }

  /// Mueve el brazo a la posición guardada en el slot [i], si existe.
  void recallArmPreset(int i) {
    final preset = armPresets[i];
    if (preset == null) return;
    setArmAngles(preset.pan, preset.tilt);
  }

  Future<void> clearArmPreset(int i) async {
    armPresets[i] = null;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_armPresetKeys[i]);
  }

  Future<void> _sendArmAngles(int panPercent, int tiltPercent) async {
    final node = deviceConfig.of(HardwareNode.esp32s3Control);
    if (node.host.isEmpty) return;
    _padArmLastPan = null; // el mando vuelve a mandar aunque repita ángulo
    final panDeg = (panPercent * 180 / 100).round();
    final tiltDeg = (tiltPercent * 180 / 100).round();
    final sw = Stopwatch()..start();
    final ok = await controlService.sendArmAngles(panDeg, tiltDeg);
    sw.stop();
    deviceConfig.reportPing(HardwareNode.esp32s3Control, ok: ok, latencyMs: ok ? sw.elapsedMilliseconds : null);
  }

  /// Igual que [pressMove] pero para los 2 servos del brazo pan/tilt.
  /// Vive en la misma placa ESP32-S3 de control (ver `Esp32ControlService`).
  Future<void> pressArm(String move) async {
    if (controlLocked) return;
    pressedArm = move;
    armStateValue = armStateMessages[move] ?? '—';
    notifyListeners();

    final node = deviceConfig.of(HardwareNode.esp32s3Control);
    if (node.host.isNotEmpty) {
      ArmCommand? cmd;
      for (final c in ArmCommand.values) {
        if (c.wireValue == move) {
          cmd = c;
          break;
        }
      }
      if (cmd != null) {
        final sw = Stopwatch()..start();
        final ok = await controlService.sendArm(cmd);
        sw.stop();
        deviceConfig.reportPing(HardwareNode.esp32s3Control, ok: ok, latencyMs: ok ? sw.elapsedMilliseconds : null);
      }
    }
  }

  // ---------------- Bloqueo de control / arranque del sistema ----------------
  // Hasta que el usuario presiona "Iniciar" en Conexiones, NADA que mueva
  // hardware (motores, brazo, LEDs manuales) se manda a las ESP32 — evita
  // que, mientras se están cargando/probando IPs, un toque suelto en otra
  // pantalla (p.ej. el D-pad, sin querer) mueva el carrito a medio
  // configurar. [controlLocked] es lo que consultan esos métodos.
  bool systemStarted = false;
  bool get controlLocked => !systemStarted;

  // ---------------- LEDs de estado (durante la vinculación) ----------------
  // Antes de "Iniciar", los 4 LEDs de la ESP32 de sensores corren solos un
  // barrido tipo "auto increíble" (ver SENSORES.ino). Cada nodo vinculado
  // EXCLUYE su LED de ese barrido (1=cámara, 2=control, 3=sensores,
  // 4=Tapo) — el usuario puede vincular 0, algunos o los 4, en cualquier
  // orden, y solo se apagan los LEDs de los nodos que sí vinculó.
  static const Map<HardwareNode, int> _statusLedForNode = {
    HardwareNode.esp32cam: 1,
    HardwareNode.esp32s3Control: 2,
    HardwareNode.esp32Sensors: 3,
    HardwareNode.tapoCam: 4,
  };
  final Map<HardwareNode, bool> _statusLedSynced = {};

  void _syncStatusLeds() {
    if (systemStarted) return; // ya pasó a control manual/por voz, ver setLed
    // Si el ESP32 de sensores (el que físicamente corre el barrido) todavía
    // no tiene IP, cualquier aviso se perdería en silencio — y si aquí lo
    // marcáramos como "ya sincronizado" igual, cuando el usuario recién
    // vincule ese ESP32 ya no se reintentaría. Por eso NO se toca
    // `_statusLedSynced` mientras no esté configurado.
    if (!sensorService.isConfigured) return;
    for (final entry in _statusLedForNode.entries) {
      final online = deviceConfig.of(entry.key).isOnline;
      if (_statusLedSynced[entry.key] == online) continue; // sin cambios, no martillar el ESP32
      _statusLedSynced[entry.key] = online;
      sensorService.setLedSequenceLinked(entry.value, online);
    }
  }

  // ---------------- IP de CONTROL para el mando de PS4 ----------------
  // El mando se empareja con la ESP32 de sensores, pero los motores y el
  // brazo viven en CONTROL — así que SENSORES necesita saber la IP de
  // CONTROL. En vez de escribirla en el firmware (y reflashear cada vez que
  // se cambia de red), la app se la manda con /controlip en cuanto
  // SENSORES responde y CONTROL tiene IP; el firmware la guarda en NVS.
  //
  // Se reenvía si cambia cualquiera de las dos IPs, y también cada vez que
  // SENSORES vuelve a estar en línea tras caerse (por si se reflasheó con
  // la memoria borrada). Solo se marca como enviada si el ESP32 respondió.
  String? _controlIpPushedKey;
  bool _controlIpPushing = false;

  Future<void> _syncControlIpToSensors() async {
    final sensors = deviceConfig.of(HardwareNode.esp32Sensors);
    final controlHost = deviceConfig.of(HardwareNode.esp32s3Control).host;
    if (!sensors.isOnline) {
      _controlIpPushedKey = null;
      return;
    }
    if (controlHost.isEmpty || _controlIpPushing) return;
    final key = '${sensors.host}|$controlHost';
    if (key == _controlIpPushedKey) return;
    _controlIpPushing = true;
    try {
      if (await sensorService.setControlHost(controlHost)) {
        _controlIpPushedKey = key;
      }
    } finally {
      _controlIpPushing = false;
    }
  }

  // ---------------- Pantalla circular de CONTROL ----------------
  // Apagada hasta presionar "Iniciar"; entonces se enciende en el menú de
  // modos del mando (Sport / Exploración / Juego). Si CONTROL no estaba en
  // línea al presionar "Iniciar", o se reinicia después (vuelve con la
  // pantalla apagada), se le vuelve a mandar en cuanto responda.
  bool _displayPushed = false;
  bool _displayPushing = false;

  Future<void> _syncDisplayToControl() async {
    if (!deviceConfig.of(HardwareNode.esp32s3Control).isOnline) {
      _displayPushed = false;
      return;
    }
    if (!systemStarted || _displayPushed || _displayPushing) return;
    _displayPushing = true;
    try {
      _displayPushed = await controlService.setDisplay(true);
    } finally {
      _displayPushing = false;
    }
  }

  /// Botón "Iniciar" de Conexiones. Detiene el barrido "auto increíble" y
  /// hace parpadear 2 veces LOS 4 LEDS JUNTOS como confirmación final —
  /// funciona igual con 0, algunos o los 4 nodos vinculados — y desbloquea
  /// el control real del carrito. A partir de aquí esos mismos 4 LEDs
  /// pasan a control manual (ver [setLed]/[setAllLeds]), así que [ledOn]
  /// arranca en apagado para todos (el barrido siempre termina así: los
  /// vinculados ya estaban excluidos/apagados, y se detiene justo antes de
  /// este parpadeo final).
  Future<void> startSystem() async {
    // Reintenta: si esta petición se pierde y el firmware nunca se entera
    // de que pare el barrido, seguiría escribiendo sobre los LEDs por
    // encima de cualquier control manual posterior (Faros, comandos de
    // voz) — este paso es crítico para el traspaso, no uno más.
    for (var i = 0; i < 3; i++) {
      if (await sensorService.stopLedSequence()) break;
    }
    for (var i = 0; i < 2; i++) {
      await sensorService.sendLed(true);
      await Future.delayed(const Duration(milliseconds: 180));
      await sensorService.sendLed(false);
      await Future.delayed(const Duration(milliseconds: 180));
    }
    for (var i = 0; i < 4; i++) {
      ledOn[i] = false;
    }
    systemStarted = true;
    notifyListeners();
    _syncDisplayToControl(); // enciende la pantalla circular (menú de modos)
  }

  // ---------------- LEDs (ESP32 sensores) ----------------
  // Estado local optimista: la ESP32 no reporta el estado de los LEDs en
  // /sensors, así que la UI lleva su propio on/off y lo manda por /led.
  // [number] es 1-4, igual que en el firmware y en LedIntent (voz).
  // Bloqueados (ver [controlLocked]) mientras no se presione "Iniciar" —
  // antes de eso, estos mismos 4 LEDs los maneja [_syncStatusLeds].
  final List<bool> ledOn = List<bool>.filled(4, false);

  Future<void> setLed(int number, bool on) async {
    if (controlLocked) return;
    ledOn[number - 1] = on;
    notifyListeners();
    await sensorService.sendLed(on, index: number);
  }

  Future<void> setAllLeds(bool on) async {
    if (controlLocked) return;
    for (var i = 0; i < 4; i++) {
      ledOn[i] = on;
    }
    notifyListeners();
    await sensorService.sendLed(on);
  }

  Future<void> toggleLed(int number) => setLed(number, !ledOn[number - 1]);

  // ---------------- Sensores de gas (MQ) ----------------
  // Solo hay 1 sensor MQ-2 (el firmware SENSORES.ino de la ESP32 de
  // sensores solo lee ese, sin multiplexor).
  final Map<String, GasReading> gasReadings = {
    'mq2': GasReading(key: 'mq2', name: 'MQ-2', type: 'Gas / Humo', value: 12),
  };

  /// Últimas 30 lecturas del MQ-2 (tendencia en Telemetría).
  final List<double> gasHistory = [];

  /// Registra una lectura nueva del MQ-2 y avisa en Alertas al
  /// cruzar el límite — es el único sensor de ambiente del carrito.
  void _setGas(double value) {
    final gas = gasReadings['mq2']!;
    final wasWarn = gas.isWarn;
    gas.value = value;
    gasHistory.add(value);
    if (gasHistory.length > 30) gasHistory.removeAt(0);
    if (gas.isWarn && !wasWarn) {
      addAlert(AppColors.red, 'Gas alto — MQ-2 en ${value.round()} %', category: 'sensores');
    } else if (!gas.isWarn && wasWarn) {
      addAlert(AppColors.green, 'Gas normal — MQ-2 en ${value.round()} %', category: 'sensores');
    }
  }

  // ---------------- Alertas ----------------
  final List<AlertEvent> alerts = [];

  void addAlert(Color level, String text, {String? category}) {
    var cat = category;
    cat ??= RegExp('sensor|gas|mq-', caseSensitive: false).hasMatch(text)
        ? 'sensores'
        : RegExp('red|conexión|wi-fi|4g|señal', caseSensitive: false).hasMatch(text)
            ? 'red'
            : 'sistema';
    alerts.insert(0, AlertEvent(time: DateTime.now(), text: text, level: level, category: cat));
    if (alerts.length > 40) alerts.removeLast();
    notifyListeners();
  }

  // ---------------- Fotos (van a Multimedia, ver `MediaLibrary`) ----------------
  bool _capturingPhoto = false;
  bool get capturingPhoto => _capturingPhoto;

  /// Toma una foto real desde la cámara [source] (ESP32-CAM vía `/capture`,
  /// o Tapo C110 con el frame actual del stream RTSP — ver
  /// `TapoCamService.captureRaw`), le aplica el filtro que tenga esa
  /// cámara y la guarda en Multimedia. Sin [source], usa [primaryCamera] —
  /// así el comando de voz "toma una foto" (que no elige cámara) sigue
  /// tomándola de la que el usuario marcó como principal. Devuelve un texto
  /// para mostrar al usuario.
  Future<String> takePhoto({AiCameraSource? source}) async {
    if (_capturingPhoto) return 'Ya se está tomando una foto…';
    _capturingPhoto = true;
    notifyListeners();

    final src = source ?? primaryCamera;
    final camName = src == AiCameraSource.tapoCam ? 'CAM 2' : 'CAM 1';
    final filter = filterOf(src); // el de ese instante, aunque lo cambien mientras se procesa

    try {
      final configured = src == AiCameraSource.tapoCam ? (tapoCamService.isConfigured || vision.iaActive) : camService.isConfigured;
      if (!configured) {
        final msg = '$camName no vinculada — no se tomó ninguna foto';
        addAlert(AppColors.yellow, msg);
        return msg;
      }

      MediaItem? item;
      if (src == AiCameraSource.tapoCam && vision.iaActive) {
        final jpeg = vision.hasFreshFrame() ? vision.frame.value : await vision.fetchPhoto();
        if (jpeg != null) item = await media.savePhoto(source: src, filter: filter, jpeg: jpeg);
      } else if (src == AiCameraSource.tapoCam) {
        final raw = await tapoCamService.captureRaw(waitForVideo: true);
        if (raw != null) item = await media.savePhoto(source: src, filter: filter, raw: raw);
      } else {
        final jpeg = await camService.capture();
        if (jpeg != null) item = await media.savePhoto(source: src, filter: filter, jpeg: Uint8List.fromList(jpeg));
      }

      if (item == null) {
        final msg = 'No se pudo capturar la foto — $camName sin respuesta';
        addAlert(AppColors.yellow, msg);
        return msg;
      }
      final withFilter = filter == CameraFilterMode.none ? '' : ' (filtro ${filter.short})';
      addAlert(AppColors.green, 'Foto de $camName guardada en Multimedia$withFilter');
      return 'Foto guardada en Multimedia$withFilter';
    } catch (e) {
      final msg = 'Foto capturada pero no se pudo guardar: $e';
      addAlert(AppColors.yellow, msg);
      return msg;
    } finally {
      _capturingPhoto = false;
      notifyListeners();
    }
  }

  /// Empieza/detiene la grabación de video de [source]. Sin [source] (botón
  /// GRABAR de la consola, pantalla completa, mando, voz) graba la cámara
  /// principal, o las 2 juntas en un solo video si [recordBoth] está
  /// activo. Devuelve un texto para mostrar al usuario.
  Future<String> toggleRecording({AiCameraSource? source}) async {
    final msg = source == null && recordBoth ? await media.toggleDualRecording() : await media.toggleRecording(source ?? primaryCamera);
    addAlert(AppColors.green, msg);
    return msg;
  }

  // ---------------- Grabar las 2 cámaras en un solo video ----------------
  static const _keyRecordBoth = 'record_both';
  bool recordBoth = false;

  Future<void> setRecordBoth(bool v) async {
    recordBoth = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyRecordBoth, v);
  }

  // ---------------- Fuente de CAM 2: RTSP directo o VISIÓN IA ----------------

  /// Hay una grabación que usa CAM 2 (sola o en el video de las 2): mientras
  /// tanto no se puede cambiar su fuente.
  bool get cam2Recording => media.isRecording(AiCameraSource.tapoCam) || media.isDualRecording;

  /// Elige la fuente de CAM 2. Devuelve un texto para avisar si no se pudo.
  Future<String?> setCam2Ia(bool ia) async {
    if (ia == vision.useIa) return null;
    if (cam2Recording) return 'Detén la grabación antes de cambiar la fuente de CAM 2';
    if (ia && !vision.available) return 'PC de visión no disponible';
    await vision.setUseIa(ia);
    return null;
  }

  /// ¿Está grabando lo que graba el botón GRABAR (principal o las 2)?
  bool get videoRecording => recordBoth ? media.isDualRecording : media.isRecording(primaryCamera);
  bool get videoToggling => recordBoth ? media.isDualToggling : media.isToggling(primaryCamera);
  Duration get videoElapsed => recordBoth ? media.dualElapsed : media.recordingElapsed(primaryCamera);

  // ---------------- Transparencia de los mandos en pantalla completa ----------------
  static const _keyFsOpacity = 'fs_controls_opacity';
  double fsControlsOpacity = 1.0; // 0.15 (casi invisibles) - 1.0

  Future<void> setFsControlsOpacity(double v) async {
    fsControlsOpacity = v.clamp(0.15, 1.0);
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_keyFsOpacity, fsControlsOpacity);
  }

  Future<void> _loadDrivePrefs() async {
    final prefs = await SharedPreferences.getInstance();
    speed = (prefs.getInt(_keySpeed) ?? speed).clamp(0, 100);
    recordBoth = prefs.getBool(_keyRecordBoth) ?? recordBoth;
    fsControlsOpacity = (prefs.getDouble(_keyFsOpacity) ?? fsControlsOpacity).clamp(0.15, 1.0);
    notifyListeners();
  }

  // ---------------- Filtros de cámara (compartidos por consola, Cámaras y
  // pantalla completa) ----------------
  CameraFilterMode esp32Filter = CameraFilterMode.none;
  CameraFilterMode tapoFilter = CameraFilterMode.none;

  CameraFilterMode filterOf(AiCameraSource src) => src == AiCameraSource.tapoCam ? tapoFilter : esp32Filter;

  void setFilter(AiCameraSource src, CameraFilterMode mode) {
    if (src == AiCameraSource.tapoCam) {
      tapoFilter = mode;
    } else {
      esp32Filter = mode;
    }
    notifyListeners();
  }

  /// La pantalla completa abre su propio stream; mientras está abierta la
  /// consola suelta el suyo (el ESP32-CAM solo atiende un /stream a la vez).
  bool fullscreenOpen = false;
  void setFullscreenOpen(bool v) {
    fullscreenOpen = v;
    notifyListeners();
  }

  // ---------------- Lectura real de sensores ----------------
  // Con la ESP32 de sensores en línea, el MQ-2 se lee de /sensors cada
  // segundo (sin ella sigue el valor de demostración). El carrito ya no
  // lleva sensor de distancia.
  Timer? _sensorTimer;
  bool _sensorPolling = false;

  void _startSensorTimer() {
    _sensorTimer ??= Timer.periodic(const Duration(seconds: 1), (_) => _pollSensors());
  }

  Future<void> _pollSensors() async {
    if (_sensorPolling || !deviceConfig.of(HardwareNode.esp32Sensors).isOnline) return;
    _sensorPolling = true;
    try {
      final p = await sensorService.poll();
      if (p == null) return;
      _setGas(p.mq2);
      notifyListeners();
    } finally {
      _sensorPolling = false;
    }
  }

  // ---------------- Ciclo de vida / demo ----------------
  void start() {
    addAlert(AppColors.green, 'SHADOW BOT en línea', category: 'sistema');
    _demoTimer = Timer.periodic(const Duration(milliseconds: 2600), (_) => _tickDemo());
    _startHealthTimer();
    _startSensorTimer();
    loadArmPresets();
    _loadPrimaryCamera();
    _loadDrivePrefs();
    _boards.start();
  }

  void _tickDemo() {
    // Sensores de gas: sigue simulando salvo que el ESP32 de sensores esté vinculado.
    final sensorsNode = deviceConfig.of(HardwareNode.esp32Sensors);
    if (!sensorsNode.isOnline) {
      _setGas((12.0 + (_rnd.nextDouble() - 0.5) * 6).clamp(2, 45));
    } else {
      // TODO(vinculación): sustituir por `sensorService.poll()` real en un
      // Timer dedicado una vez el ESP32 de sensores esté en la red.
    }

    notifyListeners();
  }

  @override
  void dispose() {
    _boards.stop();
    vision.removeListener(_syncTapoIpFromVision);
    deviceConfig.removeListener(_syncStatusLeds);
    deviceConfig.removeListener(_syncControlIpToSensors);
    deviceConfig.removeListener(_syncDisplayToControl);
    _demoTimer?.cancel();
    _healthTimer?.cancel();
    _armThrottle?.cancel();
    _holdTimer?.cancel();
    _speedSave?.cancel();
    _sensorTimer?.cancel();
    media.dispose();
    vision.dispose();
    tapoCamService.dispose();
    super.dispose();
  }
}
