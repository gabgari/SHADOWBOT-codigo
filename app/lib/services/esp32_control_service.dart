import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/node_link.dart';
import 'device_config.dart';

/// Estado de inversión de cada motor, tal como lo reporta/acepta
/// `GET /motorinvert` del firmware (persistido ahí en NVS).
class MotorInvertState {
  final bool aInverted; // motor IZQUIERDO
  final bool bInverted; // motor DERECHO
  const MotorInvertState({required this.aInverted, required this.bInverted});

  factory MotorInvertState.fromJson(Map<String, dynamic> j) => MotorInvertState(
        aInverted: j['a'] == true,
        bInverted: j['b'] == true,
      );
}

/// Lo que responde `GET /estado` del firmware de CONTROL.
class BotEstado {
  final String modo; // off | menu | sport | exploracion | juego
  final int baile; // baile pedido o en curso (0 = ninguno)
  final int seq; // cambia con cada baile nuevo
  final int t; // ms desde que arrancaron los motores (negativo = faltan)
  final int l, r; // salida de cada motor, -255..255
  final int? rssi; // señal WiFi de la placa (dBm); null en firmware viejo
  final int pag; // página del carrusel en MENÚ: 0 carátula, 1 sport, 2 exploración, 3 dance
  final int vel; // velocidad de EXPLORACIÓN (%)
  final String aev; // último evento del mando (ESP32) para la app: foto, full, cam…
  final int aseq; // cambia con cada evento nuevo
  final bool? lcdLuz; // luz de fondo del LCD 16x2; null = firmware sin LCD
  final bool lcdOk; // el LCD responde por I2C

  const BotEstado({
    required this.modo,
    required this.baile,
    required this.seq,
    required this.t,
    this.l = 0,
    this.r = 0,
    this.rssi,
    this.pag = 0,
    this.vel = 60,
    this.aev = '',
    this.aseq = 0,
    this.lcdLuz,
    this.lcdOk = false,
  });

  factory BotEstado.fromJson(Map<String, dynamic> j) => BotEstado(
        modo: j['modo'] as String? ?? 'off',
        baile: (j['baile'] as num?)?.toInt() ?? 0,
        seq: (j['seq'] as num?)?.toInt() ?? 0,
        t: (j['t'] as num?)?.toInt() ?? 0,
        l: (j['l'] as num?)?.toInt() ?? 0,
        r: (j['r'] as num?)?.toInt() ?? 0,
        rssi: (j['rssi'] as num?)?.toInt(),
        pag: (j['pag'] as num?)?.toInt() ?? 0,
        vel: (j['vel'] as num?)?.toInt() ?? 60,
        aev: j['aev'] as String? ?? '',
        aseq: (j['aseq'] as num?)?.toInt() ?? 0,
        lcdLuz: j['lcd'] == null ? null : (j['lcd'] as num) != 0,
        lcdOk: ((j['lcdok'] as num?) ?? 0) != 0,
      );
}

/// Comandos de movimiento que la pantalla Control puede enviar.
/// Deben coincidir con lo que finalmente entienda el firmware del
/// ESP32-S3 de control (aún no escrito).
enum MoveCommand {
  adelante,
  atras,
  izquierda,
  derecha,
  diagIzq,
  diagDer,
  giroIzq,
  giroDer,
  detener,
}

extension MoveCommandName on MoveCommand {
  String get wireValue => switch (this) {
        MoveCommand.adelante => 'adelante',
        MoveCommand.atras => 'atras',
        MoveCommand.izquierda => 'izquierda',
        MoveCommand.derecha => 'derecha',
        MoveCommand.diagIzq => 'diag-izq',
        MoveCommand.diagDer => 'diag-der',
        MoveCommand.giroIzq => 'giro-izq',
        MoveCommand.giroDer => 'giro-der',
        MoveCommand.detener => 'detener',
      };
}

/// Comandos del brazo de 2 ejes (pan/tilt) donde va montada la cámara.
/// Vive en la misma placa ESP32-S3 de control (junto a los BTS7960), según
/// `CODE/VINCULACION_INSPECT_BOT.md` — ahí los servos comparten controlador
/// con los motores del carrito.
enum ArmCommand {
  arriba,
  abajo,
  izquierda,
  derecha,
  arribaIzq,
  arribaDer,
  abajoIzq,
  abajoDer,
  centro,
}

extension ArmCommandName on ArmCommand {
  String get wireValue => switch (this) {
        ArmCommand.arriba => 'arriba',
        ArmCommand.abajo => 'abajo',
        ArmCommand.izquierda => 'izquierda',
        ArmCommand.derecha => 'derecha',
        ArmCommand.arribaIzq => 'arriba-izq',
        ArmCommand.arribaDer => 'arriba-der',
        ArmCommand.abajoIzq => 'abajo-izq',
        ArmCommand.abajoDer => 'abajo-der',
        ArmCommand.centro => 'centro',
      };
}

/// Cliente para el ESP32-S3 "BASE" que coordina motores (2x BTS7960) y los
/// 2 servos del brazo pan/tilt de la cámara, según el diagrama de nodos
/// del prototipo (APP -> ESP32-S3 BASE -> BTS7960 / servos). Los LEDs ya
/// NO viven aquí — pasaron al nodo ESP32 de sensores, ver
/// `Esp32SensorService.sendLed`.
///
/// El firmware de este nodo está en `firmware/CONTROL/CONTROL.ino` (raíz
/// del repo) y expone:
///
///   GET /move?dir=<adelante|atras|izquierda|derecha|diag-izq|diag-der|
///              giro-izq|giro-der|detener>&speed=<0-100>
///   GET /arm?dir=<arriba|abajo|izquierda|derecha|arriba-izq|arriba-der|
///              abajo-izq|abajo-der|centro>
///   GET /ping                                  -> 200 OK si está vivo
///   GET /motorinvert                           -> {"a":bool,"b":bool}
///   GET /motorinvert?a=<0|1>&b=<0|1>           -> cambia y persiste en la
///                                                  ESP32 (NVS), sin flashear
///   GET /display?on=1                          -> enciende la pantalla circular
///                                                  (menú de modos del mando)
///
/// Si el nodo no está configurado (sin IP en Sistema > Conexiones) o no
/// responde, [sendMove], [sendArm], [ping] y [setMotorInvert] devuelven
/// `false` (o `null` en [getMotorInvert]) sin lanzar excepción, y la UI
/// (control_screen.dart / conexiones_screen.dart) muestra el aviso
/// correspondiente en vez de fingir que el carrito, el brazo o los
/// motores cambiaron.
class Esp32ControlService {
  final DeviceConfig config;
  Esp32ControlService(this.config);

  String get _host => config.of(HardwareNode.esp32s3Control).host;
  bool get isConfigured => _host.isNotEmpty;

  /// Lados intercambiados: el motor que el firmware llama "izquierdo" está
  /// físicamente a la DERECHA (adelante/atrás bien, pero los giros salen al
  /// revés). Se corrige aquí, en la app, sin volver a flashear CONTROL:
  /// se cambian izquierda↔derecha en /move, l↔r en /movevec y en lo que
  /// muestra /estado. Lo guarda AppState en el teléfono.
  bool swapSides = true;

  /// Servo de la base (PAN) montado al revés: izquierda giraba a la
  /// derecha. Se invierte aquí (180° - ángulo, e izquierda↔derecha en /arm)
  /// sin flashear CONTROL. Lo guarda AppState en el teléfono.
  bool invertPan = true;

  /// Calibración de los BTS7960 (0-100 % cada uno, lado lógico = como lo
  /// ve el usuario): un eje tiene más torque que el otro, así que al más
  /// fuerte se le baja su % para que avance derecho. Se aplica a TODO lo que
  /// mueve las ruedas desde la app (consola, mando, voz, regreso inteligente);
  /// la velocidad general sigue funcionando igual encima de esto. Lo guarda
  /// AppState en el teléfono. Los bailes los mueve el firmware solo.
  int trimL = 100, trimR = 100;
  bool get trimActive => trimL < 100 || trimR < 100;

  // Lo que CONTROL le aplica a /movevec según el modo (ver handleMoveVec):
  // al convertir un /move calibrado a /movevec hay que compensarlo.
  String _modo = 'off';
  int _exploraVel = 60;
  int get _vecScale => switch (_modo) { 'exploracion' => _exploraVel, 'juego' => 70, _ => 100 };

  /// % que CONTROL le aplica a /movevec en el modo actual (EXPLORACIÓN = su
  /// velocidad, JUEGO = 70, el resto = 100). Para mandar una velocidad real
  /// por /movevec hay que dividir entre esto.
  int get vecScale => _vecScale;

  /// Lo mismo que `aplicarMovimiento()` de CONTROL.ino (lado lógico).
  static (int, int) wheelsFor(String dir, int speedPercent) {
    final v = (speedPercent.clamp(0, 100) * 255 / 100).round();
    final a = (v * 0.45).round(); // VEL_ARCO
    return switch (dir) {
      'adelante' => (v, v),
      'atras' => (-v, -v),
      'izquierda' => (a, v),
      'derecha' => (v, a),
      'diag-izq' => (0, v),
      'diag-der' => (v, 0),
      'giro-izq' => (-v, v),
      'giro-der' => (v, -v),
      _ => (0, 0),
    };
  }

  /// Avisa de cada orden de manejo del USUARIO (consola, mando, voz) antes
  /// de mandarla: `dir`/`speed` si es /move, `l`/`r` (lado lógico) si es
  /// /movevec (`vec`). Lo usa `AutoRoute` para grabar la ruta.
  void Function(String? dir, int speed, int l, int r, bool vec)? onUserDrive;

  static const _mirror = {
    'izquierda': 'derecha',
    'derecha': 'izquierda',
    'diag-izq': 'diag-der',
    'diag-der': 'diag-izq',
    'giro-izq': 'giro-der',
    'giro-der': 'giro-izq',
  };

  Future<bool> ping() async {
    if (!isConfigured) return false;
    try {
      final res = await http
          .get(Uri.parse('http://$_host/ping'))
          .timeout(const Duration(seconds: 3));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// TODO(vinculación): este método ya arma la petición HTTP correcta;
  /// solo falta que el ESP32-S3 de control exista en la red y entienda
  /// `/move`. Por ahora, si no hay host configurado, no intenta nada.
  Future<bool> sendMove(MoveCommand cmd, int speedPercent) async {
    if (!isConfigured) return false;
    onUserDrive?.call(cmd.wireValue, speedPercent, 0, 0, false);
    if (trimActive) {
      // Con calibración, la orden se manda por rueda (/movevec) ya ajustada.
      final (l, r) = wheelsFor(cmd.wireValue, speedPercent);
      final k = 100 / _vecScale;
      return _sendVec((l * trimL / 100 * k).round(), (r * trimR / 100 * k).round());
    }
    try {
      final uri = Uri.parse(
        'http://$_host/move?dir=${swapSides ? (_mirror[cmd.wireValue] ?? cmd.wireValue) : cmd.wireValue}&speed=$speedPercent',
      );
      final res = await http.get(uri).timeout(const Duration(seconds: 3));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  static const _armMirror = {
    'izquierda': 'derecha',
    'derecha': 'izquierda',
    'arriba-izq': 'arriba-der',
    'arriba-der': 'arriba-izq',
    'abajo-izq': 'abajo-der',
    'abajo-der': 'abajo-izq',
  };

  Future<bool> sendArm(ArmCommand cmd) async {
    if (!isConfigured) return false;
    try {
      final dir = invertPan ? (_armMirror[cmd.wireValue] ?? cmd.wireValue) : cmd.wireValue;
      final uri = Uri.parse('http://$_host/arm?dir=$dir');
      final res = await http.get(uri).timeout(const Duration(seconds: 3));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Posición absoluta del brazo (0-180° por eje) — lo que usan los
  /// sliders de pan/tilt en vez de los pasos relativos de [sendArm].
  Future<bool> sendArmAngles(int panDeg, int tiltDeg) async {
    if (!isConfigured) return false;
    if (invertPan) panDeg = 180 - panDeg.clamp(0, 180);
    try {
      final uri = Uri.parse('http://$_host/armset?pan=$panDeg&tilt=$tiltDeg');
      final res = await http.get(uri).timeout(const Duration(seconds: 3));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Enciende (o apaga) la pantalla circular GC9A01 de esta placa. Al
  /// encenderla entra al menú de modos del mando de PS4 (Sport /
  /// Exploración / Juego) — ver `AppState._syncDisplayToControl`.
  Future<bool> setDisplay(bool on) async {
    if (!isConfigured) return false;
    try {
      final uri = Uri.parse('http://$_host/display?on=${on ? 1 : 0}');
      final res = await http.get(uri).timeout(const Duration(seconds: 3));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Arranca un baile en la ESP32 (`/baile?n=`). En cuanto la placa lo
  /// acepta hay que poner la música, para que motores y audio arranquen
  /// juntos. Devuelve el `seq` del baile (ver [getEstado]; 0 si el firmware
  /// es viejo y no lo manda) o `null` si no responde o ya bailaba.
  Future<int?> startDance(int n) async {
    if (!isConfigured) return null;
    try {
      final res = await http
          .get(Uri.parse('http://$_host/baile?n=$n'))
          .timeout(const Duration(seconds: 3));
      if (res.statusCode != 200) return null;
      return int.tryParse(res.body.trim()) ?? 0;
    } catch (_) {
      return null;
    }
  }

  /// Modo actual del bot y baile en curso (`/estado`). Lo consulta
  /// `DanceMusic` ~3 veces por segundo para poner la música cuando el baile
  /// se lanza desde el mando. `null` si no responde.
  Future<BotEstado?> getEstado() async {
    if (!isConfigured) return null;
    try {
      final res = await http
          .get(Uri.parse('http://$_host/estado'))
          .timeout(const Duration(milliseconds: 1200));
      if (res.statusCode != 200) return null;
      final j = jsonDecode(res.body) as Map<String, dynamic>;
      _modo = j['modo'] as String? ?? _modo;
      _exploraVel = (j['vel'] as num?)?.toInt() ?? _exploraVel;
      if (swapSides) {
        final l = j['l'];
        j['l'] = j['r'];
        j['r'] = l;
      }
      return BotEstado.fromJson(j);
    } catch (_) {
      return null;
    }
  }

  // ---------------- Mando virtual (la app hace lo mismo que el DS4) ----------------

  /// Entra directo a un modo: menu | sport | exploracion | juego (`/modo?m=`).
  Future<bool> setMode(String mode) async {
    final ok = await _get('/modo?m=$mode');
    if (ok) _modo = mode;
    return ok;
  }

  /// Velocidad de EXPLORACIÓN, 20-100 (`/modo?vel=`).
  Future<bool> setExploraVel(int vel) async {
    final ok = await _get('/modo?vel=$vel');
    if (ok) _exploraVel = vel.clamp(20, 100);
    return ok;
  }

  /// Prende o apaga la luz de fondo del LCD 16x2 de CONTROL (`/lcd?luz=`).
  /// Solo on/off: el módulo I2C no permite regular el brillo.
  Future<bool> setLcdLight(bool on) => _get('/lcd?luz=${on ? 1 : 0}');

  /// Mismo evento que manda el mando por SENSORES (`/pad?ev=`): swipe_l,
  /// swipe_r, r1x2 (entrar), l2x2 (salir al menú), vel_up, vel_down,
  /// baile1..baile6, baile_stop.
  Future<bool> padEvent(String ev) => _get('/pad?ev=$ev');

  /// Manejo analógico por rueda (-255..255), igual que mandaba el DS4 desde
  /// SENSORES (`/movevec`). CONTROL le aplica el % de velocidad del modo y
  /// el mismo watchdog de 800 ms que a `/move`. Lo usa el mando conectado al
  /// teléfono (ver `GamepadLink`) y el regreso inteligente (`auto: true`,
  /// que no se graba como orden del usuario — ver `AutoRoute`).
  Future<bool> sendMoveVec(int left, int right, {bool auto = false}) async {
    if (!isConfigured) return false;
    if (!auto) onUserDrive?.call(null, 0, left, right, true);
    return _sendVec(left * trimL ~/ 100, right * trimR ~/ 100);
  }

  Future<bool> _sendVec(int left, int right) async {
    if (swapSides) (left, right) = (right, left);
    try {
      final res = await http
          .get(Uri.parse('http://$_host/movevec?l=${left.clamp(-255, 255)}&r=${right.clamp(-255, 255)}'))
          .timeout(const Duration(milliseconds: 600));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _get(String pathAndQuery) async {
    if (!isConfigured) return false;
    try {
      final res = await http.get(Uri.parse('http://$_host$pathAndQuery')).timeout(const Duration(seconds: 3));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Corta el baile en curso (`/baile?stop=1`).
  Future<void> stopDance() async {
    if (!isConfigured) return;
    try {
      await http.get(Uri.parse('http://$_host/baile?stop=1')).timeout(const Duration(seconds: 3));
    } catch (_) {}
  }

  /// Consulta si cada motor está marcado como invertido en la ESP32 ahora
  /// mismo. `null` si el nodo no está configurado o no responde.
  Future<MotorInvertState?> getMotorInvert() async {
    if (!isConfigured) return null;
    try {
      final uri = Uri.parse('http://$_host/motorinvert');
      final res = await http.get(uri).timeout(const Duration(seconds: 3));
      if (res.statusCode != 200) return null;
      return MotorInvertState.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  /// Invierte el sentido de giro de uno o ambos motores (para corregir un
  /// cableado espejado sin volver a flashear) — la ESP32 lo guarda en NVS.
  /// Pasa solo el/los motor(es) que quieras cambiar; `null` deja ese motor
  /// como está.
  Future<bool> setMotorInvert({bool? a, bool? b}) async {
    if (!isConfigured) return false;
    if (a == null && b == null) return true; // nada que cambiar
    try {
      final params = <String>[
        if (a != null) 'a=${a ? 1 : 0}',
        if (b != null) 'b=${b ? 1 : 0}',
      ].join('&');
      final uri = Uri.parse('http://$_host/motorinvert?$params');
      final res = await http.get(uri).timeout(const Duration(seconds: 3));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }
}
