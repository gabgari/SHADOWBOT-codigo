// =========================================================
//  SHADOWBOT · PRUEBA AISLADA: BTS7960 + SERVOS (ESP32-S3)
//  Todo se maneja desde el Monitor Serie. Sin WiFi, sin app, sin otras
//  placas. Mismos pines que CONTROL.ino: si aquí funciona, CONTROL también.
//
//  Conexiones:
//    Motor A (IZQUIERDO): RPWM=41  LPWM=40
//    Motor B (DERECHO):   RPWM=39  LPWM=38
//    BTS7960 (ambos):     VCC, R_EN, L_EN -> 3V3   ·  GND -> GND
//    Servo PAN  (naranja) -> GPIO2      Servo TILT (naranja) -> GPIO1
//    Servos: rojo -> 5 V (mejor BEC/fuente aparte) · café -> GND común
//    GND COMÚN: batería de motores, BTS7960, servos y ESP32-S3.
//
//  Arduino IDE:
//    Placa: esp32 > "ESP32S3 Dev Module"
//    USB CDC On Boot: cualquiera. El menú y los comandos funcionan por los
//                     dos conectores USB de la placa (nativo y COM).
//    PSRAM: "Disabled"            (la N16R8 usa los GPIO 35-37 para la PSRAM)
//    Librería: ESP32Servo (la misma de CONTROL.ino)
//    Monitor Serie: 115200 baudios, cualquier fin de línea.
//
//  Comandos (escribe y presiona Enter). Velocidad: -255..255
//    a 150 | a -150  -> motor A (IZQ) adelante / atrás
//    b 200 | b -200  -> motor B (DER)
//    ab 120          -> los dos iguales
//    adelante 150    -> el carrito avanza   (atras / izq / der igual)
//    inv a | inv b   -> invierte el sentido del motor A / B (si gira al revés)
//    s  (o Enter)    -> PARAR TODO
//    test            -> cada motor, cada sentido, 2 s c/u
//    rampa           -> motor A y luego B suben 0->255 poco a poco
//    juntos          -> los DOS motores a 255 por 2 s (prueba de batería)
//    pin 41 1        -> pin de motor en HIGH/LOW fijo, sin PWM (para multímetro)
//    freq 1000       -> frecuencia PWM (por defecto 20000 Hz)
//    pan 90          -> servo PAN a 90° (0..180)
//    tilt 45         -> servo TILT a 45°
//    centro          -> los dos servos a 90°
//    libre           -> suelta los servos (dejan de hacer fuerza)
//    barrido         -> los dos servos de 0 a 180 y de regreso (suave)
//    suave on|off    -> movimiento suave (acelera y frena) o directo
//    vel 200         -> velocidad máxima del brazo (grados/s)
//    acel 600        -> aceleración / frenado del brazo (grados/s²)
//    todo            -> test de motores + barrido de servos
//    estado          -> valores actuales
//    ?               -> ayuda
//
//  Seguridad: los motores se paran solos a los 10 s sin otro comando.
// =========================================================
#include <ESP32Servo.h>

#define MOTOR_A_RPWM  41
#define MOTOR_A_LPWM  40
#define MOTOR_B_RPWM  39
#define MOTOR_B_LPWM  38
#define SERVO_PAN_PIN  2
#define SERVO_TILT_PIN 1

// ---------------- Monitor Serie por los DOS puertos ----------------
// El S3 tiene dos USB: el nativo ("USB") y el del convertidor ("COM"/UART0).
// Arduino manda `Serial` a uno u otro según "USB CDC On Boot"; si el cable
// está en el otro, solo se ve el texto de arranque del chip y los comandos
// no llegan. Aquí se escribe en los dos y se lee del que mande algo, así
// funciona con cualquier conector y cualquier opción del IDE.
#if ARDUINO_USB_CDC_ON_BOOT
  #define PORT_USB  Serial    // USB nativo
  #define PORT_UART Serial0   // conector COM / UART0 (GPIO43/44)
#elif ARDUINO_USB_MODE
  #define PORT_USB  USBSerial
  #define PORT_UART Serial
#else
  #define PORT_UART Serial    // modo USB-OTG sin CDC: solo UART0
#endif

class Consola : public Stream {
public:
  void begin(unsigned long baud) {
#ifdef PORT_USB
  #if ARDUINO_USB_MODE
    PORT_USB.setTxBufferSize(4096);   // que el menú no salga cortado
  #endif
    PORT_USB.begin(baud);
  #if ARDUINO_USB_MODE
    // Si el cable va al conector COM, nadie lee el USB nativo: con esto
    // cada mensaje espera como máximo 20 ms ahí en lugar de 100 ms.
    PORT_USB.setTxTimeoutMs(20);
  #endif
#endif
    PORT_UART.begin(baud);
  }
  bool usbConectado() {
#ifdef PORT_USB
    return (bool)PORT_USB;
#else
    return false;
#endif
  }
  int available() override {
    int n = PORT_UART.available();
#ifdef PORT_USB
    n += PORT_USB.available();
#endif
    return n;
  }
  int read() override {
#ifdef PORT_USB
    if (PORT_USB.available()) return PORT_USB.read();
#endif
    return PORT_UART.read();
  }
  int peek() override {
#ifdef PORT_USB
    if (PORT_USB.available()) return PORT_USB.peek();
#endif
    return PORT_UART.peek();
  }
  size_t write(uint8_t c) override { return write(&c, 1); }
  size_t write(const uint8_t* buf, size_t n) override {
#ifdef PORT_USB
    PORT_USB.write(buf, n);   // si el USB nativo no está conectado, no espera
#endif
    PORT_UART.write(buf, n);
    return n;
  }
  void flush() override {}
};
Consola Con;

// ---------------- Motores ----------------
const int PINS[4]        = {MOTOR_A_RPWM, MOTOR_A_LPWM, MOTOR_B_RPWM, MOTOR_B_LPWM};
const char* PIN_NAMES[4] = {"A RPWM (41)", "A LPWM (40)", "B RPWM (39)", "B LPWM (38)"};

#define PWM_RES 8
uint32_t pwmFreq = 20000;

#if defined(ESP_ARDUINO_VERSION_MAJOR) && ESP_ARDUINO_VERSION_MAJOR >= 3
  #define LEDC_API_V3 1
#else
  #define LEDC_API_V3 0
#endif

bool pwmAttached[4] = {false, false, false, false};
int  pinValue[4]    = {0, 0, 0, 0};    // duty 0..255, o 0/1 en modo digital
bool pinDigital[4]  = {false, false, false, false};

bool invA = false, invB = false;   // sentido invertido (comando "inv a" / "inv b")

unsigned long lastMoveMs = 0;
bool moving = false;
const unsigned long AUTO_STOP_MS = 10000;

// ---------------- Servos ----------------
Servo servoPan, servoTilt;
int panDeg = -1, tiltDeg = -1;     // OBJETIVO de cada servo (-1 = todavía sin mover)

// Movimiento SUAVE (mismo que CONTROL.ino): en vez de saltar al ángulo, cada
// servo acelera, toma velocidad y frena antes de llegar (perfil trapezoidal).
// Se recalcula cada 10 ms y se manda en microsegundos (más fino que grados).
#define SERVO_MIN_US 500
#define SERVO_MAX_US 2400
float servoVmax = 200;   // grados/s
float servoAcel = 600;   // grados/s²
bool  servoSuave = true;
struct ServoSuave { Servo* servo; int* objetivo; float pos, vel; int lastUs; };
ServoSuave suavePan  = { &servoPan,  &panDeg,  90, 0, -1 };
ServoSuave suaveTilt = { &servoTilt, &tiltDeg, 90, 0, -1 };

// =========================================================
//  PWM (compatible core 2.x y 3.x)
// =========================================================
void pwmAttach(int i) {
  if (pwmAttached[i]) return;
#if LEDC_API_V3
  ledcAttach(PINS[i], pwmFreq, PWM_RES);
#else
  ledcSetup(i, pwmFreq, PWM_RES);
  ledcAttachPin(PINS[i], i);
#endif
  pwmAttached[i] = true;
  pinDigital[i] = false;
}

void pwmDetach(int i) {
  if (!pwmAttached[i]) return;
#if LEDC_API_V3
  ledcDetach(PINS[i]);
#else
  ledcDetachPin(PINS[i]);
#endif
  pwmAttached[i] = false;
}

void pwmWrite(int i, int duty) {
  pwmAttach(i);
  duty = constrain(duty, 0, 255);
#if LEDC_API_V3
  ledcWrite(PINS[i], duty);
#else
  ledcWrite(i, duty);
#endif
  pinValue[i] = duty;
}

// =========================================================
//  MOTORES
// =========================================================
// Nunca se ponen RPWM y LPWM altos al mismo tiempo.
void setMotor(char m, int speed) {
  speed = constrain(speed, -255, 255);
  bool inv = (m == 'A') ? invA : invB;
  int real = inv ? -speed : speed;
  int r = (m == 'A') ? 0 : 2;
  int l = r + 1;
  pwmWrite(r, 0);
  pwmWrite(l, 0);
  if (real > 0) pwmWrite(r, real);
  if (real < 0) pwmWrite(l, -real);
  Con.printf("Motor %c (%s) -> %d%s  [RPWM=%d  LPWM=%d]\n",
                m, m == 'A' ? "IZQ" : "DER", speed, inv ? " (invertido)" : "",
                pinValue[r], pinValue[l]);
}

void stopAll(bool verbose = true) {
  for (int i = 0; i < 4; i++) pwmWrite(i, 0);
  moving = false;
  if (verbose) Con.println(">> PARADO (los 4 pines en 0)");
}

void markMoving() { moving = true; lastMoveMs = millis(); }

// Espera `ms` pero se corta si llega cualquier tecla por Con.
bool waitOrAbort(unsigned long ms) {
  unsigned long t0 = millis();
  while (millis() - t0 < ms) {
    if (Con.available()) {
      while (Con.available()) Con.read();
      stopAll();
      Con.println(">> Prueba cancelada");
      return false;
    }
    servoUpdate();
    delay(2);
  }
  return true;
}

bool runTest() {
  Con.println("\n=== TEST DE MOTORES (cualquier tecla + Enter lo cancela) ===");
  struct Step { char m; int v; const char* desc; };
  const Step steps[] = {
    {'A',  180, "A IZQ adelante  (debe haber voltaje en M+/M- del BTS izquierdo)"},
    {'A', -180, "A IZQ atras"},
    {'B',  180, "B DER adelante  (debe haber voltaje en M+/M- del BTS derecho)"},
    {'B', -180, "B DER atras"},
  };
  for (const Step& s : steps) {
    Con.printf("\n-- %s\n", s.desc);
    setMotor(s.m, s.v);
    if (!waitOrAbort(2000)) return false;
    stopAll(false);
    if (!waitOrAbort(700)) return false;
  }
  stopAll();
  Con.println("=== FIN DEL TEST ===\n");
  return true;
}

void runRamp() {
  Con.println("\n=== RAMPA 0->255 (cualquier tecla + Enter la cancela) ===");
  for (char m : {'A', 'B'}) {
    Con.printf("\n-- Motor %c\n", m);
    for (int v = 0; v <= 255; v += 15) {
      setMotor(m, v);
      if (!waitOrAbort(250)) return;
    }
    stopAll(false);
    if (!waitOrAbort(700)) return;
  }
  stopAll();
  Con.println("=== FIN DE LA RAMPA ===");
  Con.println("Si solo arranca con valores altos, es normal (friccion del motor).\n");
}

void runBoth() {
  Con.println("\n=== LOS DOS MOTORES A 255 POR 2 s ===");
  Con.println("Si la placa se reinicia aqui (al volver dira BROWNOUT), la bateria/regulador no aguanta.");
  setMotor('A', 255);
  setMotor('B', 255);
  waitOrAbort(2000);
  stopAll();
}

// =========================================================
//  SERVOS
// =========================================================
// Se conectan hasta el primer comando de servo, así no brincan al prender.
bool servosAttached = false;

int gradosAUs(float g) {
  return SERVO_MIN_US + (int)(g * (SERVO_MAX_US - SERVO_MIN_US) / 180.0f + 0.5f);
}

void servoPaso(ServoSuave& m, float dt) {
  if (*m.objetivo < 0) return;              // ese servo aún no recibe orden
  float target = *m.objetivo;
  float err = target - m.pos;
  if (!servoSuave || (fabsf(err) < 0.3f && fabsf(m.vel) < 8)) {
    m.pos = target;
    m.vel = 0;
  } else {
    float vFreno = sqrtf(2 * servoAcel * fabsf(err));   // lo más rápido que aún alcanza a frenar
    float vDeseada = copysignf(min(servoVmax, vFreno), err);
    m.vel += constrain(vDeseada - m.vel, -servoAcel * dt, servoAcel * dt);
    m.pos += m.vel * dt;
    if ((target - m.pos) * err <= 0) { m.pos = target; m.vel = 0; }   // no pasarse
  }
  int us = gradosAUs(m.pos);
  if (us != m.lastUs) { m.servo->writeMicroseconds(us); m.lastUs = us; }
}

// Se llama todo el tiempo (loop y esperas): avanza los servos cada 10 ms.
void servoUpdate() {
  static unsigned long last = 0;
  if (!servosAttached || millis() - last < 10) return;
  last = millis();
  servoPaso(suavePan, 0.010f);
  servoPaso(suaveTilt, 0.010f);
}

bool servosQuietos() {
  return (panDeg < 0 || suavePan.pos == panDeg) && (tiltDeg < 0 || suaveTilt.pos == tiltDeg);
}

void servoAttachOnce() {
  if (servosAttached) return;
  servoPan.setPeriodHertz(50);
  servoTilt.setPeriodHertz(50);
  servoPan.attach(SERVO_PAN_PIN, SERVO_MIN_US, SERVO_MAX_US);
  servoTilt.attach(SERVO_TILT_PIN, SERVO_MIN_US, SERVO_MAX_US);
  // La primera vez no se sabe dónde están: se asume 90 (valor inicial de
  // pos) y de ahí parte suave. Tras "libre" se sigue desde donde se quedó.
  suavePan.vel = suaveTilt.vel = 0;
  suavePan.lastUs = suaveTilt.lastUs = -1;
  if (panDeg < 0)  panDeg = 90;
  if (tiltDeg < 0) tiltDeg = 90;
  servosAttached = true;
}

void servoDetachAll() {
  servoPan.detach();
  servoTilt.detach();
  servosAttached = false;
}

// Fija el OBJETIVO; servoUpdate() lo lleva suave. -1 = no mover ese eje.
void setServos(int pan, int tilt) {
  servoAttachOnce();
  if (pan >= 0)  panDeg  = constrain(pan, 0, 180);
  if (tilt >= 0) tiltDeg = constrain(tilt, 0, 180);
}

// Espera a que los servos lleguen a su objetivo (máx. `maxMs`).
bool waitServos(unsigned long maxMs) {
  unsigned long t0 = millis();
  while (millis() - t0 < maxMs) {
    if (!waitOrAbort(20)) return false;
    if (servosQuietos()) return true;
  }
  return true;
}

bool runSweep() {
  Con.printf("\n=== BARRIDO %s (cualquier tecla + Enter lo cancela) ===\n",
             servoSuave ? "SUAVE" : "DIRECTO");
  const int puntos[] = {0, 180, 90};
  for (int a : puntos) {
    setServos(a, a);
    Con.printf("  servos -> %d grados\n", a);
    if (!waitServos(5000)) return false;
    if (!waitOrAbort(300)) return false;
  }
  Con.println("=== FIN (servos en 90) ===");
  Con.println("Si no se movieron: mide 5V en el rojo del servo y que su GND este unido al GND del ESP32.\n");
  return true;
}

// =========================================================
//  UTILIDADES
// =========================================================
const char* resetReasonName() {
  switch (esp_reset_reason()) {
    case ESP_RST_POWERON:  return "ENCENDIDO";
    case ESP_RST_SW:       return "SOFTWARE";
    case ESP_RST_PANIC:    return "PANIC (error de codigo)";
    case ESP_RST_INT_WDT:
    case ESP_RST_TASK_WDT:
    case ESP_RST_WDT:      return "WATCHDOG";
    case ESP_RST_BROWNOUT: return "BROWNOUT (bajon de voltaje -> alimentacion)";
    case ESP_RST_EXT:      return "BOTON RESET";
    default:               return "OTRO";
  }
}

void printStatus() {
  Con.printf("\nFrecuencia PWM: %lu Hz · API LEDC: core %s\n",
                (unsigned long)pwmFreq, LEDC_API_V3 ? "3.x" : "2.x");
  for (int i = 0; i < 4; i++) {
    if (pinDigital[i]) Con.printf("  %-12s digital %s\n", PIN_NAMES[i], pinValue[i] ? "HIGH" : "LOW");
    else Con.printf("  %-12s PWM %3d/255 (~%.2f V promedio)\n", PIN_NAMES[i], pinValue[i], pinValue[i] * 3.3 / 255.0);
  }
  Con.printf("  Sentido: motor A %s · motor B %s\n",
                invA ? "INVERTIDO" : "normal", invB ? "INVERTIDO" : "normal");
  Con.printf("  Servo PAN  (GPIO%d): %s\n", SERVO_PAN_PIN, panDeg < 0 ? "sin mover" : String(panDeg).c_str());
  Con.printf("  Servo TILT (GPIO%d): %s\n", SERVO_TILT_PIN, tiltDeg < 0 ? "sin mover" : String(tiltDeg).c_str());
  Con.printf("  Servos: %s · suave %s · vel %.0f grados/s · acel %.0f grados/s2\n\n",
             servosAttached ? "con fuerza" : "sueltos", servoSuave ? "SI" : "no", servoVmax, servoAcel);
}

void printHelp() {
  Con.println(
    "\nComandos (velocidad -255..255):\n"
    "  a 150 | a -150   motor A (IZQ)\n"
    "  b 200 | b -200   motor B (DER)\n"
    "  ab 120           los dos\n"
    "  adelante 150     el carrito avanza (tambien: atras, izq, der)\n"
    "  inv a | inv b    invierte el sentido del motor A / B\n"
    "  s  (o Enter)     PARAR TODO\n"
    "  test             cada motor y sentido, 2 s c/u\n"
    "  rampa            sube la velocidad poco a poco\n"
    "  juntos           los DOS motores a 255 por 2 s (prueba de bateria)\n"
    "  pin 41 1         pin fijo HIGH/LOW sin PWM (41,40,39,38)\n"
    "  freq 1000        frecuencia PWM (100..25000 Hz)\n"
    "  pan 90 | tilt 45 servo PAN (GPIO2) / TILT (GPIO1), 0..180\n"
    "  centro | libre   servos a 90 / soltar servos\n"
    "  suave on|off     movimiento suave (acelera y frena) o directo\n"
    "  vel 200 | acel 600  velocidad (grados/s) y aceleracion del brazo\n"
    "  barrido          los dos servos de 0 a 180 y de regreso\n"
    "  todo             test de motores + barrido de servos\n"
    "  estado           valores actuales\n"
    "  ?                esta ayuda\n"
    "Los motores se paran solos a los 10 s sin comandos.\n");
}

int pinIndex(int gpio) {
  for (int i = 0; i < 4; i++) if (PINS[i] == gpio) return i;
  return -1;
}

void handleCommand(String line) {
  line.trim();
  line.toLowerCase();
  if (line.isEmpty() || line == "s" || line == "stop") { stopAll(); return; }
  if (line == "?" || line == "help" || line == "ayuda") { printHelp(); return; }
  if (line == "estado")   { printStatus(); return; }
  if (line == "test")     { runTest(); return; }
  if (line == "rampa")    { runRamp(); return; }
  if (line == "juntos")   { runBoth(); return; }
  if (line == "barrido")  { runSweep(); return; }
  if (line == "centro")   { setServos(90, 90); Con.println("Servos -> 90 grados"); return; }
  if (line == "libre")    { servoDetachAll(); Con.println("Servos sueltos (sin senal)"); return; }
  if (line == "todo") {
    if (runTest() && runSweep()) Con.println("=== PRUEBA COMPLETA TERMINADA ===\n");
    return;
  }

  int sp = line.indexOf(' ');
  String cmd = sp < 0 ? line : line.substring(0, sp);
  String arg = sp < 0 ? "" : line.substring(sp + 1);
  arg.trim();

  if (cmd == "a" || cmd == "b" || cmd == "ab") {
    if (arg.isEmpty()) { Con.println("Falta la velocidad, ej: a 150"); return; }
    int v = arg.toInt();
    if (cmd != "b") setMotor('A', v);
    if (cmd != "a") setMotor('B', v);
    if (v != 0) markMoving(); else moving = false;
    return;
  }

  if (cmd == "adelante" || cmd == "atras" || cmd == "izq" || cmd == "der") {
    int v = arg.isEmpty() ? 150 : abs(arg.toInt());
    v = constrain(v, 0, 255);
    int a = v, b = v;                         // adelante
    if (cmd == "atras") { a = -v; b = -v; }
    if (cmd == "izq")   { a = -v; b =  v; }   // gira sobre su eje
    if (cmd == "der")   { a =  v; b = -v; }
    Con.printf("Carrito: %s %d\n", cmd.c_str(), v);
    setMotor('A', a);
    setMotor('B', b);
    if (v != 0) markMoving(); else moving = false;
    Con.println("Si una rueda gira al reves: s, luego  inv a  o  inv b  y repite.");
    return;
  }

  if (cmd == "inv") {
    if (arg == "a")      invA = !invA;
    else if (arg == "b") invB = !invB;
    else { Con.println("Uso: inv a  o  inv b"); return; }
    stopAll(false);
    Con.printf("Motor %s ahora: %s (motores parados)\n", arg == "a" ? "A" : "B",
               (arg == "a" ? invA : invB) ? "INVERTIDO" : "normal");
    Con.println("En la app esto es: Sistema -> Conexiones -> Direccion de motores.");
    return;
  }

  if (cmd == "suave") {
    servoSuave = (arg != "off");
    Con.printf("Movimiento suave: %s\n", servoSuave ? "SI" : "NO (salta directo)");
    return;
  }
  if (cmd == "vel")  { servoVmax = constrain(arg.toInt(), 20, 1000);  Con.printf("Velocidad del brazo: %.0f grados/s\n", servoVmax); return; }
  if (cmd == "acel") { servoAcel = constrain(arg.toInt(), 50, 10000); Con.printf("Aceleracion del brazo: %.0f grados/s2\n", servoAcel); return; }

  if (cmd == "pan" || cmd == "tilt") {
    if (arg.isEmpty()) { Con.println("Falta el angulo, ej: pan 90"); return; }
    int a = constrain(arg.toInt(), 0, 180);
    if (cmd == "pan") setServos(a, -1); else setServos(-1, a);
    Con.printf("Servo %s (GPIO%d) -> %d grados\n", cmd == "pan" ? "PAN" : "TILT",
                  cmd == "pan" ? SERVO_PAN_PIN : SERVO_TILT_PIN, a);
    return;
  }

  if (cmd == "pin") {
    int sp2 = arg.indexOf(' ');
    if (sp2 < 0) { Con.println("Uso: pin 41 1"); return; }
    int gpio = arg.substring(0, sp2).toInt();
    int val  = arg.substring(sp2 + 1).toInt() ? 1 : 0;
    int i = pinIndex(gpio);
    if (i < 0) { Con.println("Solo pines de motor: 41, 40, 39, 38"); return; }
    // Seguridad: no dejar RPWM y LPWM del mismo motor en HIGH a la vez.
    int pair = (i % 2 == 0) ? i + 1 : i - 1;
    if (val && pinValue[pair] > 0) {
      Con.printf("Primero pon en 0 su pareja (%s): no se activan los dos lados a la vez.\n", PIN_NAMES[pair]);
      return;
    }
    pwmDetach(i);
    pinMode(PINS[i], OUTPUT);
    digitalWrite(PINS[i], val ? HIGH : LOW);
    pinDigital[i] = true;
    pinValue[i] = val;
    Con.printf("%s -> %s fijo (sin PWM). Mide ~3.3V entre este pin y GND.\n",
                  PIN_NAMES[i], val ? "HIGH" : "LOW");
    if (val) markMoving();
    return;
  }


  if (cmd == "freq") {
    long f = arg.toInt();
    if (f < 100 || f > 25000) { Con.println("Rango: 100..25000 Hz"); return; }
    stopAll(false);
    for (int i = 0; i < 4; i++) pwmDetach(i);
    pwmFreq = f;
    for (int i = 0; i < 4; i++) pwmWrite(i, 0);
    Con.printf("Frecuencia PWM = %ld Hz (motores parados)\n", f);
    return;
  }

  Con.println("Comando no reconocido. Escribe ? para ver la ayuda.");
}

// =========================================================
//  SETUP / LOOP
// =========================================================
void setup() {
  for (int i = 0; i < 4; i++) pwmWrite(i, 0);   // motores en 0 antes que nada

  Con.begin(115200);

  unsigned long t0 = millis();
  // Espera a que abras el monitor por el USB nativo; por el conector COM no
  // se puede saber, así que como máximo son 3 s.
  while (!Con.usbConectado() && millis() - t0 < 3000) delay(10);
  delay(300);

  Con.println("\n==============================================");
  Con.println(" SHADOWBOT - PRUEBA AISLADA: BTS7960 + SERVOS");
  Con.println("==============================================");
  Con.printf("Causa del ultimo reinicio: %s\n", resetReasonName());
  printStatus();
  printHelp();
  Con.println("Sugerencia: empieza con  todo");
}

String buffer;
unsigned long lastHintMs = 0;
unsigned long lastRxMs = 0;
bool gotAnyInput = false;
bool prevWasCR = false;

void runLine() {
  String cmd = buffer;
  buffer = "";
  cmd.trim();
  // Eco: confirma en pantalla que el comando SÍ llegó a la placa.
  Con.printf("\n> %s\n", cmd.length() ? cmd.c_str() : "(Enter)");
  handleCommand(cmd);
}

void loop() {
  servoUpdate();
  while (Con.available()) {
    char c = Con.read();
    gotAnyInput = true;
    lastRxMs = millis();
    // Acepta "Nueva línea" (\n), "Retorno de carro" (\r) o "Ambos" (\r\n).
    // En "Ambos", el \n que viene justo después del \r se ignora — si no,
    // contaría como un Enter vacío (= PARAR) justo después de cada comando.
    if (c == '\n' && prevWasCR) { prevWasCR = false; continue; }
    prevWasCR = (c == '\r');
    if (c == '\r' || c == '\n') runLine();
    else if (buffer.length() < 40) buffer += c;
  }
  // Monitor en "Sin fin de línea": ejecuta lo escrito tras 400 ms sin más letras.
  if (buffer.length() && millis() - lastRxMs > 400) runLine();

  if (!gotAnyInput && millis() - lastHintMs > 15000) {
    lastHintMs = millis();
    Con.println("[esperando comando: escribe ? y presiona Enter]");
  }
  if (moving && millis() - lastMoveMs > AUTO_STOP_MS) {
    Con.println(">> 10 s sin comandos: parada automatica de seguridad");
    stopAll();
  }
}
