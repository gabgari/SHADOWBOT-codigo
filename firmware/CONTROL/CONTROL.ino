// =========================================================
//  SHADOW BOT · ESP32-S3 "CONTROL"  —  VERSIÓN CON LCD 16x2 I2C
//  Motores (2x BTS7960 vía LEDC) + brazo pan/tilt (2 servos) + LCD 16x2.
//  La pantalla GC9A01 se quitó del proyecto (ya no hay LovyanGFX, LVGL,
//  carátula ni fuego); la sustituye un LCD 16x2 I2C que muestra el modo y
//  el MQ-2. La app y SENSORES funcionan sin cambios (mismos endpoints).
//
//  Conexiones:
//    BTS7960 IZQUIERDO: RPWM -> GPIO41   LPWM -> GPIO40
//    BTS7960 DERECHO:   RPWM -> GPIO39   LPWM -> GPIO38
//    BTS7960 (ambos):   VCC, R_EN, L_EN -> 3V3   ·   GND -> GND
//    Servo PAN  (naranja) -> GPIO2      Servo TILT (naranja) -> GPIO1
//    Servos: rojo -> 5 V (mejor BEC/fuente aparte) · café -> GND común
//    GND COMÚN entre batería de motores, BTS7960, servos y ESP32-S3.
//    LCD 16x2 I2C: GND -> GND · VCC -> 5V · SDA -> GPIO14 · SCL -> GPIO13
//      (4 pines seguidos al final de la tira izquierda: 13, 14, 5V, GND)
//      (jumper "LED" puesto = luz de fondo; potenciómetro azul = contraste)
//
//  Arduino IDE: placa "ESP32S3 Dev Module", PSRAM: "Disabled" (la N16R8
//  usa los GPIO 35-37 para la PSRAM). Librería: "ESP32Servo".
//
//  Misma lógica que PRUEBA_BTS_SERVOS (la prueba aislada que ya funciona):
//    - Monitor Serie (115200) con los mismos comandos: a 150, b -150,
//      adelante 150, s, pan 90, tilt 45, centro, barrido, estado, ?...
//      Si por Serie funciona y con la app no, el problema está en la red o
//      en la app, no en la placa.
//    - Servos SUAVES: aceleran y frenan solos (perfil trapezoidal) en vez
//      de saltar al ángulo. Se ajusta con "suave on|off", "vel" y "acel".
//
//  API HTTP que consume la app (esp32_control_service.dart):
//    GET /ping                                   -> "OK"
//    GET /move?dir=<...>&speed=<0-100>            -> mueve el carrito (dirección con nombre)
//    GET /movevec?l=<-255..255>&r=<-255..255>     -> mueve el carrito por rueda directo
//                                                     (mando de PS4 conectado al teléfono: la app lo reenvía);
//                                                     misma cola y watchdog de 800ms que /move
//    GET /arm?dir=<...>                           -> mueve el brazo (paso relativo, por voz)
//    GET /armset?pan=<0-180>&tilt=<0-180>         -> posición absoluta del brazo (sliders)
//    GET /motorinvert                             -> {"a":bool,"b":bool} (estado actual)
//    GET /motorinvert?a=<0|1>&b=<0|1>             -> invierte el sentido de giro (se guarda en NVS)
//    GET /display?on=<0|1>                        -> la app lo manda al presionar "Iniciar":
//                                                     activa el menú de modos (ya sin pantalla)
//    GET /pad?ev=<evento>                         -> eventos del mando de PS4 (los reenvía la app)
//    GET /telemetry?mq2=<%>                       -> MQ-2 que manda SENSORES (se acepta y se ignora
//                                                     en lo visual; ya no hay tablero)
//    GET /mode                                    -> modo actual: off|menu|sport|exploracion|juego
//    GET /modo?m=<modo> | /modo?vel=<20-100>      -> la app cambia de modo / velocidad EXPLORACIÓN
//    GET /baile?n=<1-6> | /baile?stop=1           -> baile desde la app (5-6 con canción)
//    GET /estado                                  -> JSON de estado para la app
//    GET /lcd?luz=<0|1>                           -> prende/apaga la luz del LCD 16x2 (se guarda)
//
//  Arquitectura anti-lag: /move y /movevec solo escriben en una cola de
//  FreeRTOS de tamaño 1 (gana siempre el comando más reciente) y un task
//  aparte (motorTask, core 0) aplica el movimiento y lleva el watchdog de
//  800 ms. WiFi.setSleep(false) evita el lag intermitente del radio.
//  Compatible con arduino-esp32 core 2.x y 3.x (bloque LEDC_API_V3).
// =========================================================
#include <WiFi.h>
#include <WebServer.h>

#include <WiFiUdp.h>             // avisos de IP por la red (ver announceTick)
#include <ESP32Servo.h>          // Instalar: "ESP32Servo" (Kevin Harrington) desde el Library Manager
#include <Preferences.h>         // guarda la inversión de motores en NVS (sobrevive a reinicios)

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/queue.h"

// =============================================================
//  MONITOR SERIE POR LOS DOS PUERTOS (igual que PRUEBA_BTS_SERVOS)
// =============================================================
// El S3 tiene dos USB: el nativo y el del convertidor (COM / UART0). Se
// escribe en los dos y se lee del que mande algo: funciona con cualquier
// conector y cualquier opción "USB CDC On Boot". En el USB nativo la
// escritura NUNCA espera: si nadie lee, el texto se descarta y los
// motores no se retrasan.
#if ARDUINO_USB_CDC_ON_BOOT
  #define PORT_USB  Serial
  #define PORT_UART Serial0
#elif ARDUINO_USB_MODE
  #define PORT_USB  USBSerial
  #define PORT_UART Serial
#else
  #define PORT_UART Serial
#endif

class Consola : public Stream {
public:
  void begin(unsigned long baud) {
#ifdef PORT_USB
  #if ARDUINO_USB_MODE
    PORT_USB.setTxBufferSize(4096);
  #endif
    PORT_USB.begin(baud);
  #if ARDUINO_USB_MODE
    PORT_USB.setTxTimeoutMs(0);
  #endif
#endif
    PORT_UART.begin(baud);
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
    PORT_USB.write(buf, n);
#endif
    PORT_UART.write(buf, n);
    return n;
  }
  void flush() override {}
};
Consola Con;

// ── WiFi (misma red que la cámara y sensores) ────────────
const char* ssid     = "TU_RED_WIFI";
const char* password = "TU_CONTRASENA_WIFI";

// ── Aviso de IP por UDP (en vez de Telegram) ──────────────
// El HTTPS que pide Telegram ocupa ~133 KB y con eso CONTROL no cabía en la
// partición por defecto. Ahora cada 3 s manda un broadcast UDP chiquito
// ("SHADOWBOT-CONTROL") y CAMARA, que sí tiene Telegram, manda al bot
// "IP CONTROL: x". El mismo puerto sirve para oír a SENSORES (ver
// announceTick) y pasarle la IP de esta placa.
WiFiUDP announceUdp;
const uint16_t ANNOUNCE_PORT = 4210;
unsigned long nextAnnounceMs = 0;

// ── Pines BTS7960 ────────────────────────────────────────
#define MOTOR_A_RPWM  41
#define MOTOR_A_LPWM  40
#define MOTOR_B_RPWM  39
#define MOTOR_B_LPWM  38

// Con el cableado actual NINGÚN motor queda espejado, por eso los dos en
// `false`. Estos son solo los valores por default de FÁBRICA (primera vez
// que arranca la placa, antes de que la app guarde nada). Para invertir un
// motor YA NO hace falta tocar este código ni volver a flashear: se hace
// desde la app (Sistema > Conexiones > "Dirección de motores"), que llama
// a GET /motorinvert?a=..&b=.. — la placa lo guarda en NVS (memoria que no
// se borra al apagar) y lo vuelve a cargar solo en cada arranque.
#define MOTOR_A_INVERTED_DEFAULT false   // motor IZQUIERDO
#define MOTOR_B_INVERTED_DEFAULT false   // motor DERECHO

Preferences motorPrefs;
bool motorAInverted = MOTOR_A_INVERTED_DEFAULT;
bool motorBInverted = MOTOR_B_INVERTED_DEFAULT;

// ── Pines Servos ─────────────────────────────────────────
#define SERVO_PAN_PIN  2    // antes 37: en N16R8 los GPIO 35-37 son de la PSRAM octal
#define SERVO_TILT_PIN 1    // antes 36

// ── LEDC PWM (compatible con arduino-esp32 core 2.x y 3.x) ──────
// Core 3.0 cambió toda la API de LEDC (quitó ledcSetup/ledcAttachPin y el
// concepto de "canal" manual). Detectamos la versión instalada y usamos la
// forma que corresponda — así el mismo .ino compila y funciona en ambas.
#if defined(ESP_ARDUINO_VERSION_MAJOR) && ESP_ARDUINO_VERSION_MAJOR >= 3
  #define LEDC_API_V3 1
#else
  #define LEDC_API_V3 0
#endif

#define PWM_FREQ 20000
#define PWM_RES  8
// Canales manuales — solo se usan en core 2.x (LEDC_API_V3==0). En core
// 3.x, ledcAttach/ledcWrite trabajan directo por PIN, sin canal.
#define CH_A_FWD 0
#define CH_A_BWD 1
#define CH_B_FWD 2
#define CH_B_BWD 3

// Fracción de velocidad para la rueda "lenta" en curvas suaves (izquierda/derecha)
const float VEL_ARCO = 0.45;

// Paso en grados por cada pulsación del pad del brazo
const int PASO_SERVO = 10;

// Watchdog: si el task de motores deja de recibir /move, para solo.
const unsigned long CMD_TIMEOUT_MS = 800;

WebServer server(80);
Servo servoPan;
Servo servoTilt;

volatile int panAngle  = 90;   // OBJETIVO del brazo (lo que pidió la app / el baile)
volatile int tiltAngle = 90;

// =============================================================
//  SERVOS SUAVES
// =============================================================
// En vez de saltar directo al ángulo (se siente "robótico"), cada servo
// avanza hacia su objetivo con aceleración y frenado (perfil trapezoidal):
// arranca despacio, toma velocidad y frena antes de llegar, sin pasarse.
// servoTask lo recalcula cada 10 ms y lo manda en microsegundos (más fino
// que grados enteros). Los bailes usan valores más rápidos para no perder
// el ritmo.
#define SERVO_MIN_US 500
#define SERVO_MAX_US 2400
float servoVmax = 200;          // °/s   velocidad máxima normal
float servoAcel = 600;          // °/s²  aceleración / frenado normal
const float BAILE_VMAX = 450;   // °/s   en los bailes
const float BAILE_ACEL = 2500;  // °/s²
bool  servoSuave = true;        // false = salta directo (como antes)

struct ServoSuave {
  Servo* servo;
  volatile int* objetivo;       // &panAngle o &tiltAngle
  float pos, vel;
  int   lastUs;
};
ServoSuave suavePan, suaveTilt;  // se inicializan en setup()

int gradosAUs(float g) {
  return SERVO_MIN_US + (int)(g * (SERVO_MAX_US - SERVO_MIN_US) / 180.0f + 0.5f);
}

void servoPaso(ServoSuave& m, float dt, float vmax, float acel) {
  float target = *m.objetivo;
  float err = target - m.pos;
  if (!servoSuave || (fabsf(err) < 0.3f && fabsf(m.vel) < 8)) {
    m.pos = target;
    m.vel = 0;
  } else {
    float vFreno = sqrtf(2 * acel * fabsf(err));        // lo más rápido que aún alcanza a frenar
    float vDeseada = copysignf(min(vmax, vFreno), err);
    float dv = constrain(vDeseada - m.vel, -acel * dt, acel * dt);
    m.vel += dv;
    m.pos += m.vel * dt;
    if ((target - m.pos) * err <= 0) { m.pos = target; m.vel = 0; }   // no pasarse
  }
  int us = gradosAUs(m.pos);
  if (us != m.lastUs) { m.servo->writeMicroseconds(us); m.lastUs = us; }
}

volatile bool danceActive = false;   // (declarada aquí: servoTask la usa)

void servoTask(void*) {
  TickType_t last = xTaskGetTickCount();
  for (;;) {
    vTaskDelayUntil(&last, pdMS_TO_TICKS(10));
    float vmax = danceActive ? BAILE_VMAX : servoVmax;
    float acel = danceActive ? BAILE_ACEL : servoAcel;
    servoPaso(suavePan, 0.010f, vmax, acel);
    servoPaso(suaveTilt, 0.010f, vmax, acel);
  }
}

// Única forma de mover el brazo: fija el OBJETIVO y servoTask lo lleva suave.
// -1 = no mover ese eje.
void brazoA(int pan, int tilt) {
  if (pan  >= 0) panAngle  = constrain(pan, 0, 180);
  if (tilt >= 0) tiltAngle = constrain(tilt, 0, 180);
}

// Comando de movimiento en tránsito hacia motorTask. Cola de tamaño 1: ver
// nota de arquitectura arriba (siempre gana el comando más reciente).
// raw=false -> viene de /move (dirección con nombre + velocidad 0-100%).
// raw=true  -> viene de /movevec (velocidad directa -255..255 por rueda,
//              usado por el mando de PS4 conectado al teléfono).
struct MoveCmd {
  bool raw;
  char dir[12];
  uint8_t speed;
  int16_t rawLeft;
  int16_t rawRight;
  uint16_t holdMs;   // 0 = watchdog normal (800 ms). Los comandos del Monitor Serie usan 3000.
};
QueueHandle_t moveQueue;

// =============================================================
//  MOTORES
// =============================================================
// Última velocidad aplicada a cada rueda (-255..255, antes de invertir):
// la app la lee en /estado (l, r).
volatile int16_t motorOutL = 0, motorOutR = 0;

void motorIzq(int v) {
  v = constrain(v, -255, 255);
  motorOutL = v;
  if (motorAInverted) v = -v; // motor IZQUIERDO espejado en el cableado físico
#if LEDC_API_V3
  ledcWrite(MOTOR_A_RPWM, v > 0 ? v : 0);
  ledcWrite(MOTOR_A_LPWM, v < 0 ? -v : 0);
#else
  ledcWrite(CH_A_FWD, v > 0 ? v : 0);
  ledcWrite(CH_A_BWD, v < 0 ? -v : 0);
#endif
}

void motorDer(int v) {
  v = constrain(v, -255, 255);
  motorOutR = v;
  if (motorBInverted) v = -v; // motor DERECHO espejado en el cableado físico
#if LEDC_API_V3
  ledcWrite(MOTOR_B_RPWM, v > 0 ? v : 0);
  ledcWrite(MOTOR_B_LPWM, v < 0 ? -v : 0);
#else
  ledcWrite(CH_B_FWD, v > 0 ? v : 0);
  ledcWrite(CH_B_BWD, v < 0 ? -v : 0);
#endif
}

void stopMotors() { motorIzq(0); motorDer(0); }

void aplicarMovimiento(const String& dir, int speedPercent) {
  int v    = map(constrain(speedPercent, 0, 100), 0, 100, 0, 255);
  int arco = (int)(v * VEL_ARCO);
  // Diagnóstico: si esto NUNCA aparece en el Serial Monitor mientras tocas
  // el D-pad en la app, el problema es de red/vinculación (revisa que el
  // ESP32-S3 esté vinculado en Conexiones y que ya hayas dado "Iniciar" —
  // ver AppState.controlLocked), no del BTS7960. Si SÍ aparece pero el
  // motor no gira, el problema es cableado/alimentación del BTS7960.
  Con.printf("aplicarMovimiento dir=%s speed=%d%% -> v=%d\n", dir.c_str(), speedPercent, v);

  if      (dir == "adelante")   { motorIzq( v);     motorDer( v);    }
  else if (dir == "atras")      { motorIzq(-v);     motorDer(-v);    }
  else if (dir == "izquierda")  { motorIzq( arco);  motorDer( v);    } // curva suave izq
  else if (dir == "derecha")    { motorIzq( v);     motorDer( arco); } // curva suave der
  else if (dir == "diag-izq")   { motorIzq( 0);     motorDer( v);    } // curva cerrada izq
  else if (dir == "diag-der")   { motorIzq( v);     motorDer( 0);    } // curva cerrada der
  else if (dir == "giro-izq")   { motorIzq(-v);     motorDer( v);    } // pivote sobre su eje
  else if (dir == "giro-der")   { motorIzq( v);     motorDer(-v);    }
  else /* "detener" u otro */   { stopMotors();                      }
}

// Control directo por rueda (-255..255 cada una), sin pasar por las
// direcciones con nombre ni por VEL_ARCO — pensado para el mando de PS4
// (la app ya manda los valores por rueda mezclados).
void aplicarMovimientoRaw(int left, int right) {
  static int prevL = 9999, prevR = 9999;   // solo se imprime si cambia (el mando manda cada 100 ms)
  if (left != prevL || right != prevR) Con.printf("aplicarMovimientoRaw L=%d R=%d\n", left, right);
  prevL = left; prevR = right;
  motorIzq(left);
  motorDer(right);
}

// =============================================================
//  MODOS (antes se elegían en la pantalla; ahora desde la app o el mando)
// =============================================================
//   OFF   -> al prender. La app y el mando manejan el carrito normal.
//   MENU  -> la app presionó "Iniciar". Con el mando: deslizar el touchpad
//            cambia de página y 2x R1 entra; mientras tanto el mando NO mueve
//            el carrito. La app entra directo a un modo con /modo?m=...
//   SPORT -> velocidad máxima. EXPLORACION -> velocidad ajustable (20-100%).
//   JUEGO -> bailes (✕ ○ □ △ en el mando, o /baile desde la app).
//   En cualquier modo, 2x L2 regresa al MENU.

// Estado compartido: lo cambian los handlers HTTP / motorTask.
//
enum Screen { SCR_OFF = 0, SCR_MENU, SCR_SPORT, SCR_EXPLORA, SCR_JUEGO };
volatile int screen   = SCR_OFF;
volatile int menuIdx  = 0;               // 0=CARÁTULA 1=SPORT 2=EXPLORACION 3=JUEGO (DANCE)
volatile int menuDir  = 1;               // sentido del último swipe (animación)
volatile int exploraVel = 60;            // % de velocidad en EXPLORACION (20-100)
const int JUEGO_VEL   = 70;              // % de velocidad del mando en JUEGO
const int MENU_PAGES  = 4;               // 0=inicio 1=SPORT 2=EXPLORACION 3=JUEGO

// Última lectura que manda SENSORES con /telemetry (solo informativa).
volatile float telMq2  = -1;
volatile unsigned long telLastMs = 0;

const char* modeName() {
  switch (screen) {
    case SCR_MENU:    return "menu";
    case SCR_SPORT:   return "sport";
    case SCR_EXPLORA: return "exploracion";
    case SCR_JUEGO:   return "juego";
    default:          return "off";
  }
}

// ---- Bailes (modo JUEGO) ----
// Cada paso: velocidad izq/der (-255..255), pan/tilt (-1 = no mover) y
// duración. Corren en motorTask (core 0), igual que el resto del movimiento.
struct DanceStep { int16_t l, r, pan, tilt; uint16_t ms; };
const int D = 190;
const DanceStep BAILE_GIRO[] = {      // ✕  "Giro loco"
  { D, -D,  50, -1, 600}, {-D,  D, 130, -1, 600},
  { D, -D,  50, -1, 600}, {-D,  D, 130, -1, 600}, {0, 0, 90, -1, 200},
};
const DanceStep BAILE_ZIGZAG[] = {    // ○  "Zigzag"
  { D, D/4, 60, -1, 350}, {D/4, D, 120, -1, 350},
  { D, D/4, 60, -1, 350}, {D/4, D, 120, -1, 350},
  { D, D/4, 60, -1, 350}, {D/4, D, 120, -1, 350},
  {-D, -D,  90, -1, 700}, {0, 0, 90, -1, 200},
};
const DanceStep BAILE_SINO[] = {      // □  "Sí y no" (cabeceo + negación)
  {0, 0, 90,  60, 250}, {0, 0, 90, 120, 250}, {0, 0, 90,  60, 250}, {0, 0, 90, 120, 250},
  {0, 0, 90,  90, 150},
  { 120, -120,  50, -1, 200}, {-120,  120, 130, -1, 200},
  { 120, -120,  50, -1, 200}, {-120,  120, 130, -1, 200}, {0, 0, 90, 90, 200},
};
const DanceStep BAILE_TWIST[] = {     // △  "Twist"
  { D, -D,  40, 130, 200}, {-D,  D, 140,  50, 200},
  { D, -D,  40, 130, 200}, {-D,  D, 140,  50, 200},
  { D,  D,  90,  90, 400}, {-D, -D,  90,  90, 400}, {0, 0, 90, 90, 200},
};
// ---- Bailes CON CANCIÓN (los lanza la app con /baile?n=5..6 y ella pone
// el audio en el celular). Cada coreografía dura lo mismo que su tramo de
// canción; los pasos van al ritmo (1 "B" = 1 tiempo de la canción).
// Pasos: {motor izq, motor der, pan, tilt, ms}  (-1 en pan/tilt = no mover)

// "Everybody" — Backstreet Boys, coro (EVERYBODY DANCE.mp3: 21.5 s, 108 BPM,
// 39 tiempos).
const uint16_t BE = 556;
const DanceStep BAILE_EVERYBODY[] = {
  // "Everybody (yeah), rock your body (yeah)": sacudida en su lugar + cabeceo
  { 120,-120, 70, 70,BE}, {-120, 120,110,110,BE}, { 120,-120, 70, 70,BE}, {-120, 120,110,110,BE},
  { 120,-120, 70, 70,BE}, {-120, 120,110,110,BE}, { 120,-120, 70, 70,BE}, {-120, 120,110,110,BE},
  // adelante / atrás mirando a los lados
  { 170, 170, 60, 90,BE}, { 170, 170,120, 90,BE}, {-170,-170, 60, 90,BE}, {-170,-170,120, 90,BE},
  { 170, 170, 60, 90,BE}, { 170, 170,120, 90,BE}, {-170,-170, 60, 90,BE}, {-170,-170,120, 90,BE},
  // "Everybody": giro a un lado, al otro, y 4 cabeceos quieto
  {-190, 190, 40, 90,2*BE}, { 190,-190,140, 90,2*BE},
  {   0,   0, 90, 60,BE}, {   0,   0, 90,120,BE}, {   0,   0, 90, 60,BE}, {   0,   0, 90,120,BE},
  // "Rock your body right": zigzag hacia adelante
  { 200,  80, 60, 80,BE}, {  80, 200,120, 80,BE}, { 200,  80, 60, 80,BE}, {  80, 200,120, 80,BE},
  { 200,  80, 60, 80,BE}, {  80, 200,120, 80,BE}, { 200,  80, 60, 80,BE}, {  80, 200,120, 80,BE},
  // "Backstreet's back, alright!": vuelta completa y pose final
  { 220,-220, 90, 90,4*BE}, {   0,   0, 30, 50,BE}, {   0,   0,150, 50,BE}, {   0,   0, 90, 40,BE},
};

// "Tokyo Drift" — Teriyaki Boyz (TOKIODRIFT DANCE.mp3: 13.6 s): donas y giros
// en su eje.
const DanceStep BAILE_TOKYO[] = {
  { 100,-100, 90, 90, 600}, { 160,-160, 90, 90, 600}, { 220,-220, 90, 90, 600},  // arranca girando en su eje
  { 255,  70, 60, 90,3200},                                                      // dona (derrape) a la derecha
  {-240, 240,120, 90,2000},                                                      // en su eje, al revés
  {  70, 255,120, 90,3200},                                                      // dona a la izquierda
  { 255,-255, 90, 70,1900},                                                      // giro a tope
  {   0,   0, 90, 60, 700}, {   0,   0, 90,110, 800},                            // "Fast and Furious": pose
};

struct Dance { const char* name; const DanceStep* steps; int count; };
#define DANCE(n, s) {n, s, (int)(sizeof(s) / sizeof(s[0]))}
// 1-4: los del mando (modo JUEGO: ✕ ○ □ △). 5-6: con canción, desde la app.
const Dance DANCES[] = {
  DANCE("GIRO LOCO", BAILE_GIRO), DANCE("ZIGZAG", BAILE_ZIGZAG),
  DANCE("SI Y NO", BAILE_SINO),   DANCE("TWIST", BAILE_TWIST),
  DANCE("EVERYBODY", BAILE_EVERYBODY), DANCE("TOKYO DRIFT", BAILE_TOKYO),
};
const int DANCE_N = sizeof(DANCES) / sizeof(DANCES[0]);

volatile int  danceReq    = 0;       // 1..6 = baile pedido (lo toma motorTask)
volatile bool danceCancel = false;
volatile int  danceShown  = -1;      // índice del baile en curso (-1 = ninguno)
// Para que la app ponga la música de los bailes que se lanzan desde el mando
// (la consulta en /estado): número del baile pedido o en curso (0 = ninguno),
// un contador que cambia con cada baile y el millis() en que arrancan los
// motores. Los de canción lanzados con el mando esperan DANCE_LEAD_MS antes
// de moverse, para que la app alcance a enterarse y arranque la música junto.
const unsigned long DANCE_LEAD_MS = 900;
volatile int           danceCur     = 0;
volatile uint32_t      danceSeq     = 0;
volatile unsigned long danceStartAt = 0;

bool danceHasSong(int n) { return n >= 5 && n <= DANCE_N; }

// Registra un baile pedido (desde el mando o la app); lo corre motorTask.
void requestDance(int n, unsigned long leadMs) {
  danceSeq++;
  danceStartAt = millis() + leadMs;
  danceCur = n;
  danceReq = n;
}

// Espera `ms` en rebanadas cortas para poder cancelar (2x L2) a media secuencia.
bool danceWait(uint16_t ms) {
  for (uint16_t t = 0; t < ms; t += 20) {
    if (danceCancel) return false;
    vTaskDelay(pdMS_TO_TICKS(20));
  }
  return true;
}

void runDance(int n) {
  const Dance& d = DANCES[n - 1];
  int savedPan = panAngle, savedTilt = tiltAngle;
  danceActive = true;
  danceShown = n - 1;
  Con.printf("Baile %d: %s\n", n, d.name);
  long lead = (long)(danceStartAt - millis());   // cuenta regresiva (bailes con canción)
  bool ok = lead <= 0 || danceWait((uint16_t)min(lead, 5000L));
  for (int i = 0; ok && i < d.count; i++) {
    const DanceStep& s = d.steps[i];
    motorIzq(s.l);
    motorDer(s.r);
    brazoA(s.pan, s.tilt);
    if (!danceWait(s.ms)) break;
  }
  stopMotors();
  brazoA(savedPan, savedTilt);  // el brazo vuelve (suave) a donde lo dejó el usuario
  danceCancel = false;
  danceActive = false;
  danceShown = -1;
  if (!danceReq) danceCur = 0;
}

// Cambia de modo. Cualquier cambio frena el carrito y corta un
// baile a medias — nunca se entra a un modo nuevo con los motores andando.
void setScreen(int s) {
  if (s == screen) return;
  if (danceActive) danceCancel = true;
  MoveCmd stop = {};
  stop.raw = true;
  xQueueOverwrite(moveQueue, &stop);
  screen = s;
  Con.printf("Modo -> %s\n", modeName());
}

// =============================================================
//  TASK DE MOTORES (FreeRTOS) — core 0, separado del WebServer (core 1).
//  Consume el último /move o /movevec de moveQueue y lleva el watchdog. Al
//  vivir en su propio task, nunca lo retrasa un bloqueo del stack WiFi/HTTP.
// =============================================================
void motorTask(void* pvParameters) {
  MoveCmd cmd;
  unsigned long lastCmdTime = 0;
  unsigned long timeoutMs = CMD_TIMEOUT_MS;
  bool moviendose = false;

  for (;;) {
    // Baile pedido desde el mando (modo JUEGO): corre completo aquí mismo y
    // al terminar descarta cualquier comando que haya llegado mientras tanto.
    if (danceReq) {
      int n = danceReq;
      danceReq = 0;
      runDance(n);
      xQueueReset(moveQueue);
      moviendose = false;
      continue;
    }
    // Espera hasta 100ms por un comando nuevo; si no llega, revisa el
    // watchdog. Así el freno de emergencia corre siempre a tiempo,
    // aunque no llegue ningún /move ni /movevec nuevo.
    if (xQueueReceive(moveQueue, &cmd, pdMS_TO_TICKS(100)) == pdTRUE) {
      if (cmd.raw) {
        aplicarMovimientoRaw(cmd.rawLeft, cmd.rawRight);
        moviendose = (cmd.rawLeft != 0 || cmd.rawRight != 0);
      } else {
        aplicarMovimiento(String(cmd.dir), cmd.speed);
        moviendose = (strcmp(cmd.dir, "detener") != 0);
      }
      lastCmdTime = millis();
      timeoutMs = cmd.holdMs ? cmd.holdMs : CMD_TIMEOUT_MS;
    } else if (moviendose && millis() - lastCmdTime > timeoutMs) {
      stopMotors();
      moviendose = false;
      Con.println(">> watchdog: sin comandos nuevos, motores parados");
    }
  }
}

// =============================================================
//  BRAZO (servos pan/tilt)
// =============================================================
void aplicarBrazo(const String& dir) {
  int pan = panAngle, tilt = tiltAngle;
  if (dir == "centro") { pan = 90; tilt = 90; }
  else {
    if      (dir == "izquierda")  { pan  -= PASO_SERVO; }
    else if (dir == "derecha")    { pan  += PASO_SERVO; }
    else if (dir == "arriba")     { tilt += PASO_SERVO; }
    else if (dir == "abajo")      { tilt -= PASO_SERVO; }
    else if (dir == "arriba-izq") { tilt += PASO_SERVO; pan -= PASO_SERVO; }
    else if (dir == "arriba-der") { tilt += PASO_SERVO; pan += PASO_SERVO; }
    else if (dir == "abajo-izq")  { tilt -= PASO_SERVO; pan -= PASO_SERVO; }
    else if (dir == "abajo-der")  { tilt -= PASO_SERVO; pan += PASO_SERVO; }
  }
  brazoA(pan, tilt);
}

// =============================================================
//  HTTP
// =============================================================
void sendOk(const String& body = "OK") {
  server.sendHeader("Access-Control-Allow-Origin", "*");
  server.send(200, "text/plain", body);
}
void sendError(int code, const String& msg) {
  server.sendHeader("Access-Control-Allow-Origin", "*");
  server.send(code, "text/plain", msg);
}

void handlePing() { sendOk(); }

void handleMove() {
  if (!server.hasArg("dir")) { sendError(400, "falta dir"); return; }
  MoveCmd cmd = {};
  cmd.raw = false;
  server.arg("dir").toCharArray(cmd.dir, sizeof(cmd.dir));
  int speed = server.hasArg("speed") ? server.arg("speed").toInt() : 60;
  cmd.speed = (uint8_t)constrain(speed, 0, 100);
  xQueueOverwrite(moveQueue, &cmd);   // no bloquea nunca; gana el comando más reciente
  sendOk();
}

// Control directo por rueda (mando de PS4 conectado al teléfono).
// Usa la MISMA cola/watchdog que /move: si dejan de llegar peticiones
// (se soltó el stick, se apagó el mando, se cayó el WiFi), el carrito
// frena solo a los 800ms, igual que con /move.
void handleMoveVec() {
  if (!server.hasArg("l") || !server.hasArg("r")) { sendError(400, "faltan l/r"); return; }
  int l = constrain(server.arg("l").toInt(), -255, 255);
  int r = constrain(server.arg("r").toInt(), -255, 255);
  // Velocidad según el modo elegido (solo afecta al mando;
  // /move de la app tiene su propio control de velocidad).
  switch (screen) {
    // MENU: antes el carrito se quedaba quieto mientras se elegía el modo en
    // la pantalla redonda. Sin pantalla no se ve que estás en el menú y el
    // mando parecía no funcionar, así que ahora maneja normal (100%).
    case SCR_EXPLORA: l = l * exploraVel / 100; r = r * exploraVel / 100; break;
    case SCR_JUEGO:   l = l * JUEGO_VEL / 100;  r = r * JUEGO_VEL / 100;  break;
    default: break;                                              // OFF y SPORT: 100%
  }
  if (!danceActive) {                                            // bailando: manda el baile
    MoveCmd cmd = {};
    cmd.raw = true;
    cmd.rawLeft  = (int16_t)l;
    cmd.rawRight = (int16_t)r;
    xQueueOverwrite(moveQueue, &cmd);
  }
  sendOk(modeName());   // SENSORES lee el modo de aquí (se llama cada 100ms)
}

// La app manda on=1 al presionar "Iniciar": se activa el carrusel de modos
// (empieza en la carátula). on=0 regresa a la carátula fija y al manejo normal.
void handleDisplay() {
  if (server.hasArg("on")) {
    bool on = server.arg("on").toInt() != 0;
    if (on && screen == SCR_OFF) { menuIdx = 0; setScreen(SCR_MENU); }
    else if (!on)                setScreen(SCR_OFF);
  }
  sendOk(modeName());
}

// Eventos del mando de PS4 (los reenvía la app). Si el evento no aplica al
// modo actual se ignora sin error — responde siempre con el modo vigente.
// Eventos "app_*": acciones que solo puede hacer la app (foto, pantalla
// completa, cambiar cámara, filtro, IA, posiciones del brazo, paro). El mando
// en SENSORES (ESP32) los manda aquí y la app los recoge de /estado (aev/aseq).
char appEv[24] = "";
volatile uint32_t appEvSeq = 0;

void padEvent(const String& ev) {
  if (ev.startsWith("app_")) {
    strncpy(appEv, ev.c_str() + 4, sizeof(appEv) - 1);
    appEv[sizeof(appEv) - 1] = 0;
    appEvSeq++;
    return;
  }
  if (screen == SCR_MENU) {
    if (ev == "swipe_r")      { menuDir =  1; menuIdx = (menuIdx + 1) % MENU_PAGES; }
    else if (ev == "swipe_l") { menuDir = -1; menuIdx = (menuIdx + MENU_PAGES - 1) % MENU_PAGES; }
    else if (ev == "r1x2" && menuIdx > 0) { setScreen(SCR_SPORT + menuIdx - 1); }   // la carátula no es un modo
  } else if (screen != SCR_OFF) {
    if (ev == "l2x2") {
      menuIdx = screen - SCR_SPORT + 1;   // el menú abre en el modo del que se salió
      setScreen(SCR_MENU);
    } else if (screen == SCR_EXPLORA && (ev == "vel_up" || ev == "vel_down")) {
      exploraVel = constrain(exploraVel + (ev == "vel_up" ? 20 : -20), 20, 100);
    } else if (screen == SCR_JUEGO && ev == "baile_stop") {
      if (danceActive) danceCancel = true;
      danceReq = 0;
      if (!danceActive) danceCur = 0;
    } else if (screen == SCR_JUEGO && ev.startsWith("baile") && !danceActive && !danceReq) {
      int n = ev.substring(5).toInt();
      if (n >= 1 && n <= DANCE_N) requestDance(n, danceHasSong(n) ? DANCE_LEAD_MS : 0);
    }
  }
}

void handlePad() {
  padEvent(server.arg("ev"));
  sendOk(modeName());
}

// La app como "mando": entra directo a un modo sin pasar por el carrusel
// (el mando físico queda como extra). También ajusta la velocidad de
// EXPLORACIÓN.
//   /modo?m=menu|sport|exploracion|juego   -> cambia de modo
//   /modo?vel=<20-100>                     -> velocidad de EXPLORACIÓN
void handleModo() {
  if (server.hasArg("m")) {
    String m = server.arg("m");
    int s = m == "sport" ? SCR_SPORT : m == "exploracion" ? SCR_EXPLORA : m == "juego" ? SCR_JUEGO : m == "menu" ? SCR_MENU : -1;
    if (s < 0) { sendError(400, "modo desconocido"); return; }
    if (s == SCR_MENU) menuIdx = screen >= SCR_SPORT ? screen - SCR_SPORT + 1 : 0;
    setScreen(s);
  }
  if (server.hasArg("vel")) exploraVel = constrain((int)server.arg("vel").toInt(), 20, 100);
  sendOk(modeName());
}

void handleMode() { sendOk(modeName()); }

// Bailes desde la app (los de canción: 5 = Everybody, 6 = Tokyo Drift;
// también sirven 1-4). La app pone el audio en el celular
// justo cuando recibe la respuesta, así motores y música arrancan juntos.
//   /baile?n=<1-6>   -> empieza (pasa al modo JUEGO)
//   /baile?stop=1    -> corta el baile
void handleBaile() {
  if (server.hasArg("stop")) {
    if (danceActive) danceCancel = true;
    danceReq = 0;
    if (!danceActive) danceCur = 0;
    sendOk("stop");
    return;
  }
  int n = server.arg("n").toInt();
  if (n < 1 || n > DANCE_N) { sendError(400, "n fuera de rango"); return; }
  if (danceActive || danceReq) { sendError(409, "ya esta bailando"); return; }
  if (screen != SCR_JUEGO) setScreen(SCR_JUEGO);
  requestDance(n, 0);
  MoveCmd wake = {};                  // despierta a motorTask ya (sin esperar 100 ms)
  wake.raw = true;
  xQueueOverwrite(moveQueue, &wake);
  sendOk(String((unsigned long)danceSeq));   // la app lo usa para reconocer su propio baile
}

// Estado para la app (la consulta ~3 veces por segundo):
//   {"modo":"juego","baile":6,"seq":12,"t":-420,"l":0,"r":0,"rssi":-51}
// baile = número pedido o en curso (0 = ninguno); seq cambia con cada baile;
// t = ms desde que arrancan (o arrancarán, si es negativo) los motores.
// l/r = salida actual de cada motor (-255..255); rssi = señal WiFi (dBm).
// pag = página del carrusel en MENÚ (0 carátula, 1 sport, 2 exploración, 3 dance);
// vel = velocidad de EXPLORACIÓN (%); aev/aseq = último evento del mando para la app.
// Causa del último reinicio (diagnóstico): BROWNOUT = bajón de voltaje.
const char* resetReasonName() {
  switch (esp_reset_reason()) {
    case ESP_RST_POWERON:  return "ENCENDIDO";
    case ESP_RST_SW:       return "SOFTWARE";
    case ESP_RST_PANIC:    return "PANIC (error de codigo)";
    case ESP_RST_INT_WDT:
    case ESP_RST_TASK_WDT:
    case ESP_RST_WDT:      return "WATCHDOG";
    case ESP_RST_BROWNOUT: return "BROWNOUT (bajon de voltaje)";
    case ESP_RST_EXT:      return "BOTON RESET";
    default:               return "OTRO";
  }
}

// Variables del LCD (definidas más abajo, en la sección del LCD 16x2).
extern volatile bool lcdLuz;
extern volatile bool lcdSucio;
extern uint8_t lcdAddr;

void handleEstado() {
  int n = danceCur;
  long t = n ? (long)(millis() - danceStartAt) : 0;
  char buf[320];
  // "rst" y "up" (segundos encendida): en http://IP/estado se ve si la placa
  // se reinicia al mover motores (up vuelve a 0 y rst dice BROWNOUT).
  snprintf(buf, sizeof(buf),
           "{\"modo\":\"%s\",\"baile\":%d,\"seq\":%lu,\"t\":%ld,\"l\":%d,\"r\":%d,\"rssi\":%d,\"pag\":%d,\"vel\":%d,\"aev\":\"%s\",\"aseq\":%lu,\"rst\":\"%s\",\"up\":%lu,\"lcd\":%d,\"lcdok\":%d}",
           modeName(), n, (unsigned long)danceSeq, t, (int)motorOutL, (int)motorOutR, (int)WiFi.RSSI(),
           (int)menuIdx, (int)exploraVel, appEv, (unsigned long)appEvSeq, resetReasonName(),
           millis() / 1000, lcdLuz ? 1 : 0, lcdAddr ? 1 : 0);
  server.sendHeader("Access-Control-Allow-Origin", "*");
  server.sendHeader("Cache-Control", "no-store");
  server.send(200, "application/json", buf);
}

// Luz de fondo del LCD 16x2 (botón de la app y L2 + Options del mando).
// Solo on/off: el módulo I2C no permite regular el brillo. Se guarda en NVS.
void handleLcd() {
  if (server.hasArg("luz")) {
    lcdLuz = server.arg("luz").toInt() != 0;
    lcdSucio = true;                     // se reenvía todo con la luz nueva
    motorPrefs.putBool("lcdLuz", lcdLuz);
  }
  char buf[48];
  snprintf(buf, sizeof(buf), "{\"luz\":%s,\"ok\":%s}", lcdLuz ? "true" : "false", lcdAddr ? "true" : "false");
  server.sendHeader("Access-Control-Allow-Origin", "*");
  server.send(200, "application/json", buf);
}

// SENSORES manda el MQ-2 cada ~500ms. Antes era para el tablero de la
// pantalla; se sigue aceptando para que SENSORES no cambie.
void handleTelemetry() {
  if (server.hasArg("mq2"))  telMq2  = server.arg("mq2").toFloat();
  telLastMs = millis();
  sendOk(modeName());
}

void handleArm() {
  if (!server.hasArg("dir")) { sendError(400, "falta dir"); return; }
  if (!danceActive) aplicarBrazo(server.arg("dir"));
  sendOk();
}

// Posición absoluta (0-180°) para los sliders de la app — a diferencia de
// /arm (pasos relativos, usado por los comandos de voz), esto mueve el
// servo directo al ángulo pedido, como el barrido continuo de un slider.
void handleArmSet() {
  if (!server.hasArg("pan") || !server.hasArg("tilt")) { sendError(400, "faltan pan/tilt"); return; }
  if (danceActive) { sendOk(); return; }   // el baile controla el brazo
  brazoA(server.arg("pan").toInt(), server.arg("tilt").toInt());
  sendOk();
}

// Sin argumentos: consulta el estado actual. Con a=<0|1> y/o b=<0|1>:
// cambia la inversión de ese motor y la guarda en NVS (sobrevive a
// reinicios) — así se corrige el sentido de giro desde la app, sin
// volver a flashear el firmware.
void handleMotorInvert() {
  bool changed = false;
  if (server.hasArg("a")) {
    motorAInverted = server.arg("a").toInt() != 0;
    motorPrefs.putBool("aInv", motorAInverted);
    changed = true;
  }
  if (server.hasArg("b")) {
    motorBInverted = server.arg("b").toInt() != 0;
    motorPrefs.putBool("bInv", motorBInverted);
    changed = true;
  }
  if (changed) stopMotors();   // por seguridad: no seguir moviéndose con el sentido a medio cambiar

  String json = "{\"a\":";
  json += motorAInverted ? "true" : "false";
  json += ",\"b\":";
  json += motorBInverted ? "true" : "false";
  json += "}";
  server.sendHeader("Access-Control-Allow-Origin", "*");
  server.send(200, "application/json", json);
}

// =============================================================
//  LCD 16x2 I2C (sustituye a la GC9A01)
// =============================================================
// Módulo con "mochila" PCF8574 (la plaquita negra de atrás):
//   GND -> GND · VCC -> 5V · SDA -> GPIO14 · SCL -> GPIO13
//   En la placa son 4 pines SEGUIDOS al final de la tira izquierda
//   (13, 14, 5V, GND): mismo orden que el módulo, cables derechos.
//   Si SDA y SCL quedan al revés, el código lo detecta y funciona igual.
//   Jumper "LED": prende la luz de fondo. DÉJALO PUESTO.
//   Potenciómetro azul: es el CONTRASTE. Si prende pero no ves letras (o
//   solo cuadritos), gíralo despacio con un desarmador hasta que aparezcan.
// Driver propio (sin librerías extra): HD44780 en 4 bits a través del
// PCF8574. La dirección (0x27, 0x3F...) se busca sola al arrancar.
// Todo el LCD vive en lcdTask (core 1, prioridad baja): nunca frena los
// motores ni el servidor, y solo se manda al LCD lo que cambió.
//
//  Pantalla (16 columnas x 2 filas):
//   [ícono 2x2] [MODO    ] | MQ-2
//   [ícono 2x2] [detalle ] |  12%
//   STANDARD (sin modo) -> calavera que guiña · SPORT -> rayo + tacómetro
//   EXPLORACIÓN -> lupa + velocidad · JUEGO -> nota + baile en curso
//   Gas arriba de 35 % (mismo límite que la app) -> "GAS!" parpadeando.
#include <Wire.h>

#define LCD_SDA 14
#define LCD_SCL 13
const float GAS_LIMITE = 35;            // % (igual que la alerta "Gas alto" de la app)

uint8_t lcdAddr  = 0;                   // 0 = no encontrado
volatile bool lcdLuz = true;            // luz de fondo (comando "luz on|off")
volatile bool lcdSucio = true;          // true = redibujar todo
bool    lcdError = false;
char    lcdQuiero[2][16], lcdHay[2][16];
int     lcdIconoActual = -1;
unsigned long lcdInicioMs = 0;

// ---- bajo nivel: PCF8574 -> HD44780 (P0=RS P1=RW P2=EN P3=LUZ P4-P7=D4-D7) ----
void lcdNibble(uint8_t hi, uint8_t rs) {
  uint8_t d = (hi & 0xF0) | rs | (lcdLuz ? 0x08 : 0);
  Wire.beginTransmission(lcdAddr);
  Wire.write(d | 0x04);                 // EN alto
  Wire.write(d);                        // EN bajo: aquí el LCD lee el dato
  if (Wire.endTransmission() != 0) lcdError = true;
}
void lcdByte(uint8_t v, uint8_t rs) { lcdNibble(v, rs); lcdNibble(v << 4, rs); delayMicroseconds(40); }
void lcdCmd(uint8_t c)  { lcdByte(c, 0); if (c <= 3) delay(2); }   // clear/home tardan ~1.5 ms
void lcdChar(uint8_t c) { lcdByte(c, 1); }

void lcdCrear(uint8_t slot, const uint8_t filas[8]) {
  lcdCmd(0x40 | (slot << 3));
  for (int i = 0; i < 8; i++) lcdChar(filas[i]);
  lcdSucio = true;                      // la dirección quedó en CGRAM: hay que reposicionar
}

// ---- Íconos de 2x2 caracteres (10 x 16 puntos). Se dibujan aquí con '#'
// y se convierten solos: si quieres cambiar uno, edita el dibujo. ----
const char* const ICO_CALAVERA[16] = {
  "..######..", ".########.", "##########", "##########",
  "#...##...#", "#...##...#", "#...##...#", "##########",
  "####..####", ".###..###.", ".########.", "..######..",
  "..#.##.#..", "..######..", "..#.##.#..", "...####...",
};
const char* const ICO_CALAVERA_GUINO[16] = {   // ojo derecho cerrado
  "..######..", ".########.", "##########", "##########",
  "#...######", "#...#....#", "#...######", "##########",
  "####..####", ".###..###.", ".########.", "..######..",
  "..#.##.#..", "..######..", "..#.##.#..", "...####...",
};
const char* const ICO_RAYO[16] = {
  "....######", "...######.", "...#####..", "..#####...",
  "..####....", ".#########", ".########.", ".....####.",
  ".....###..", "....###...", "....##....", "...##.....",
  "...#......", "..#.......", "..........", "..........",
};
const char* const ICO_LUPA[16] = {
  "..........", "...####...", "..#....#..", ".#......#.",
  ".#......#.", ".#......#.", ".#......#.", "..#....#..",
  "...####...", ".....##...", "......##..", ".......##.",
  "........##", ".........#", "..........", "..........",
};
const char* const ICO_NOTA[16] = {
  "....######", "....######", "....#....#", "....#....#",
  "....#....#", "....#....#", "....#....#", "....#....#",
  "....#....#", "....#..###", "..###.####", ".####.####",
  ".####..##.", "..##......", "..........", "..........",
};
const char* const* const ICONOS[] = { ICO_CALAVERA, ICO_CALAVERA_GUINO, ICO_RAYO, ICO_LUPA, ICO_NOTA };
enum { I_CALAVERA = 0, I_GUINO, I_RAYO, I_LUPA, I_NOTA };

// Slots fijos de CGRAM: 0-3 = ícono del modo, 4 = separador, 5 = medio
// bloque y 6 = riel vacío (tacómetro de SPORT).
const uint8_t CH_SEPARADOR[8] = {0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04};
const uint8_t CH_MEDIO[8]     = {0x1C, 0x1C, 0x1C, 0x1C, 0x1C, 0x1C, 0x1C, 0x1C};
const uint8_t CH_RIEL[8]      = {0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x1F};

void lcdIcono(int n) {
  if (n == lcdIconoActual) return;
  const char* const* art = ICONOS[n];
  for (int c = 0; c < 4; c++) {          // 0 arriba-izq, 1 arriba-der, 2 abajo-izq, 3 abajo-der
    uint8_t filas[8];
    for (int r = 0; r < 8; r++) {
      const char* linea = art[(c / 2) * 8 + r];
      uint8_t b = 0;
      for (int x = 0; x < 5; x++) if (linea[(c % 2) * 5 + x] == '#') b |= 0x10 >> x;
      filas[r] = b;
    }
    lcdCrear(c, filas);
  }
  lcdIconoActual = n;
}

// Pines con los que se encontró el LCD (si SDA y SCL están al revés en el
// cableado, se detecta y se usa así, sin tener que moverlos).
int lcdSdaPin = LCD_SDA, lcdSclPin = LCD_SCL;
bool lcdVerbose = true;   // detalle de cada intento (solo la primera búsqueda)

bool lcdIniciar() {
  const uint8_t dirs[] = {0x27, 0x3F, 0x26, 0x25, 0x24, 0x23, 0x22, 0x21, 0x20,
                          0x3E, 0x3D, 0x3C, 0x3B, 0x3A, 0x39, 0x38};
  lcdAddr = 0;
  for (uint8_t a : dirs) {
    Wire.beginTransmission(a);
    if (Wire.endTransmission() == 0) { lcdAddr = a; break; }
  }
  // Si no está en las direcciones típicas, se busca en todas.
  for (uint8_t a = 0x08; !lcdAddr && a <= 0x77; a++) {
    Wire.beginTransmission(a);
    if (Wire.endTransmission() == 0) lcdAddr = a;
  }
  if (lcdVerbose) Con.printf("  I2C SDA=GPIO%d SCL=GPIO%d -> %s", lcdSdaPin, lcdSclPin, lcdAddr ? "responde en " : "nadie responde\n");
  if (!lcdAddr) return false;
  if (lcdVerbose) Con.printf("0x%02X\n", lcdAddr);
  lcdError = false;
  delay(50);
  lcdNibble(0x30, 0); delay(5);          // secuencia de arranque del HD44780 (datasheet)
  lcdNibble(0x30, 0); delay(1);
  lcdNibble(0x30, 0); delay(1);
  lcdNibble(0x20, 0); delay(1);          // modo 4 bits
  lcdCmd(0x28);                          // 2 líneas, 5x8
  lcdCmd(0x0C);                          // display ON, sin cursor
  lcdCmd(0x06);                          // escribe hacia la derecha
  lcdCmd(0x01);                          // borrar
  lcdCrear(4, CH_SEPARADOR);
  lcdCrear(5, CH_MEDIO);
  lcdCrear(6, CH_RIEL);
  lcdIconoActual = -1;
  lcdSucio = true;
  lcdInicioMs = millis();
  return !lcdError;
}

// Escribe `s` en la fila/columna, rellenando con espacios hasta `ancho`.
void lcdTexto(int fila, int col, const char* s, int ancho) {
  for (int i = 0; i < ancho && col + i < 16; i++) {
    char ch = *s ? *s++ : ' ';
    lcdQuiero[fila][col + i] = ch;
  }
}

// Arma en lcdQuiero lo que debe verse ahora.
void lcdDibujar() {
  memset(lcdQuiero, ' ', sizeof(lcdQuiero));
  unsigned long t = millis();

  if (t - lcdInicioMs < 1500) {          // presentación al arrancar
    lcdIcono(I_CALAVERA);
    lcdQuiero[0][0] = 0; lcdQuiero[0][1] = 1; lcdQuiero[1][0] = 2; lcdQuiero[1][1] = 3;
    lcdTexto(0, 3, "SHADOWBOT", 13);
    lcdTexto(1, 3, "iniciando...", 13);
    return;
  }

  int scr = screen;
  char detalle[9] = "";
  const char* nombre;
  if (scr == SCR_OFF || scr == SCR_MENU) {
    // Sin modo = STANDARD, con la calavera (guiña ~cada 4 s).
    lcdIcono(((t / 200) % 20) == 0 ? I_GUINO : I_CALAVERA);
    nombre = "STANDARD";
    if (WiFi.status() != WL_CONNECTED) strcpy(detalle, "SIN WIFI");
    else if (scr == SCR_MENU) {
      static const char* const PAG[] = {"INICIO", "SPORT", "EXPLORA", "JUEGO"};
      snprintf(detalle, sizeof(detalle), "<%s>", PAG[menuIdx % 4]);
    } else strcpy(detalle, "LISTO");
  } else if (scr == SCR_SPORT) {
    lcdIcono(I_RAYO);
    nombre = "SPORT";
  } else if (scr == SCR_EXPLORA) {
    lcdIcono(I_LUPA);
    nombre = "EXPLORA";
    snprintf(detalle, sizeof(detalle), "VEL %d%%", (int)exploraVel);
  } else {
    lcdIcono(I_NOTA);
    nombre = "JUEGO";
    int d = danceShown;
    if (d >= 0 && d < DANCE_N) snprintf(detalle, sizeof(detalle), "%s", DANCES[d].name);
    else strcpy(detalle, "ELIGE");
  }
  lcdQuiero[0][0] = 0; lcdQuiero[0][1] = 1;
  lcdQuiero[1][0] = 2; lcdQuiero[1][1] = 3;
  lcdTexto(0, 3, nombre, 8);
  if (scr == SCR_SPORT) {
    // Tacómetro: 8 celdas = 16 medios pasos de la rueda más rápida.
    int v = max(abs((int)motorOutL), abs((int)motorOutR));
    int medios = (v * 16 + 254) / 255;
    for (int i = 0; i < 8; i++) {
      int resto = medios - i * 2;
      lcdQuiero[1][3 + i] = resto >= 2 ? (char)0xFF : resto == 1 ? 5 : 6;
    }
  } else {
    lcdTexto(1, 3, detalle, 8);
  }

  // Separador y MQ-2 (lo manda SENSORES con /telemetry cada 0.5 s).
  lcdQuiero[0][11] = 4;
  lcdQuiero[1][11] = 4;
  bool sinDato = telLastMs == 0 || t - telLastMs > 5000;
  float gas = telMq2;
  bool alerta = !sinDato && gas > GAS_LIMITE;
  lcdTexto(0, 12, alerta && (t / 400) % 2 ? "GAS!" : "MQ-2", 4);
  char val[6];
  if (sinDato) strcpy(val, " ---");
  else snprintf(val, sizeof(val), "%3d%%", (int)(gas + 0.5f));
  lcdTexto(1, 12, val, 4);
}

// Manda al LCD solo las letras que cambiaron.
void lcdVolcar() {
  bool todo = lcdSucio;
  lcdSucio = false;
  int cursor = -1;
  for (int f = 0; f < 2; f++) {
    for (int c = 0; c < 16; c++) {
      char q = lcdQuiero[f][c];
      if (!todo && q == lcdHay[f][c]) continue;
      int pos = f * 16 + c;
      if (pos != cursor) lcdCmd(0x80 | (c + (f ? 0x40 : 0)));
      lcdChar((uint8_t)q);
      lcdHay[f][c] = q;
      cursor = (c == 15) ? -1 : pos + 1;
    }
  }
}


// GPIO libres donde podrían haber quedado los cables del LCD por error (no
// se tocan los de motores, servos, USB, UART, flash/PSRAM ni el botón BOOT).
const uint8_t LCD_CANDIDATOS[] = {4, 5, 6, 7, 8, 9, 10, 11, 12, 15, 16, 17, 18, 21, 42, 47, 48};
uint8_t lcdAltos[sizeof(LCD_CANDIDATOS)];
int     lcdNAltos = 0;
char    lcdOtros[80] = "";

// Las resistencias del módulo dejan SDA y SCL en ALTO: un GPIO libre que lee
// ALTO con pull-down interno es casi seguro un cable del LCD.
void lcdBuscarCables() {
  lcdNAltos = 0;
  lcdOtros[0] = 0;
  for (uint8_t g : LCD_CANDIDATOS) {
    pinMode(g, INPUT_PULLDOWN);
    delayMicroseconds(300);
    if (digitalRead(g)) {
      lcdAltos[lcdNAltos++] = g;
      char t[8];
      snprintf(t, sizeof(t), "GPIO%d ", g);
      strncat(lcdOtros, t, sizeof(lcdOtros) - strlen(lcdOtros) - 1);
    }
    pinMode(g, INPUT);
  }
}

// Mide los dos pines sin I2C: con el módulo conectado, sus resistencias
// los dejan en ALTO. Si alguno está en BAJO, ese cable está suelto/en corto
// o el GND del LCD no es el mismo que el de la ESP32-S3.
void lcdDiagnostico() {
  Wire.end();
  pinMode(LCD_SDA, INPUT_PULLDOWN);
  pinMode(LCD_SCL, INPUT_PULLDOWN);
  delay(5);
  int sda = digitalRead(LCD_SDA), scl = digitalRead(LCD_SCL);
  // Segunda medición con pull-UP: si aun así lee BAJO, ese pin está en corto
  // a GND (o el cable va a GND). Si lee ALTO, el pin está al aire (suelto).
  pinMode(LCD_SDA, INPUT_PULLUP);
  pinMode(LCD_SCL, INPUT_PULLUP);
  delay(5);
  int sdaUp = digitalRead(LCD_SDA), sclUp = digitalRead(LCD_SCL);
  pinMode(LCD_SDA, INPUT);
  pinMode(LCD_SCL, INPUT);
  lcdBuscarCables();
  Con.println("---- DIAGNOSTICO LCD I2C ----");
  Con.printf("GPIO%d (SDA): %s   GPIO%d (SCL): %s\n", LCD_SDA, sda ? "ALTO (ok)" : "BAJO", LCD_SCL, scl ? "ALTO (ok)" : "BAJO");
  auto estado = [](int down, int up) {
    return down ? "con resistencias del LCD (ok)" : up ? "AL AIRE: el cable no llega al modulo" : "EN CORTO A GND";
  };
  Con.printf("SDA: %s\nSCL: %s\n", estado(sda, sdaUp), estado(scl, sclUp));
  if (sda && scl)
    Con.println("Los dos cables llegan, pero el modulo no contesta en ninguna direccion.\n"
                "Revisa que GND del LCD vaya al GND de la ESP32-S3 y que los cables esten firmes.");
  else
    Con.println("Un pin en BAJO = ese cable NO llega al LCD (suelto, en otro pin o pin del\n"
                "protoboard malo). Revisa SDA -> GPIO14 y SCL -> GPIO13, y GND comun.");
  if (lcdOtros[0]) Con.printf("Cables del LCD detectados en otros pines: %s\n", lcdOtros);
  else Con.println("No se detectan los cables del LCD en ningun GPIO libre.");
  Con.println("Se probo tambien con SDA y SCL al reves. Reintento cada 3 s.");
  Con.println("-----------------------------");
}

void lcdTask(void*) {
  unsigned long reintento = 0;
  bool avisado = false;
  int intento = 0;
  for (;;) {
    if (!lcdAddr) {
      if (millis() >= reintento) {
        // Intento normal (8/9) y luego al revés (9/8).
        bool encontrado = false;
        for (int k = 0; k < 2 && !encontrado; k++) {
          lcdSdaPin = k == 0 ? LCD_SDA : LCD_SCL;
          lcdSclPin = k == 0 ? LCD_SCL : LCD_SDA;
          Wire.end();
          Wire.begin(lcdSdaPin, lcdSclPin, 100000);   // el PCF8574 va hasta 100 kHz
          encontrado = lcdIniciar();
        }
        if (!encontrado) {
          // ¿Quedaron los cables en otros pines? Se prueban todas las parejas.
          Wire.end();
          lcdBuscarCables();
          for (int i = 0; i < lcdNAltos && !encontrado; i++)
            for (int j = 0; j < lcdNAltos && !encontrado; j++) {
              if (i == j) continue;
              lcdSdaPin = lcdAltos[i];
              lcdSclPin = lcdAltos[j];
              Wire.end();
              Wire.begin(lcdSdaPin, lcdSclPin, 100000);
              encontrado = lcdIniciar();
            }
          if (!encontrado) Wire.end();
        }
        if (encontrado) {
          Con.printf("LCD I2C encontrado en 0x%02X (SDA=GPIO%d SCL=GPIO%d)\n", lcdAddr, lcdSdaPin, lcdSclPin);
          if (lcdSdaPin == LCD_SCL && lcdSclPin == LCD_SDA)
            Con.println("Nota: SDA y SCL estan al reves en el cableado. Funciona igual asi.");
          else if (lcdSdaPin != LCD_SDA)
            Con.printf("Nota: el LCD esta en GPIO%d/GPIO%d, no en 14/13. Funciona igual; el diagrama dice SDA=14 SCL=13.\n",
                       lcdSdaPin, lcdSclPin);
          avisado = false;
        } else {
          lcdAddr = 0;
          if (!avisado || ++intento % 20 == 0) lcdDiagnostico();   // al inicio y luego cada ~1 min
          lcdVerbose = false;
          avisado = true;
          reintento = millis() + 3000;
        }
      }
    } else {
      lcdDibujar();
      lcdVolcar();
      if (lcdError) {
        Con.println("LCD I2C: se perdio la conexion, reintentando...");
        lcdAddr = 0;
        reintento = millis() + 1000;
      }
    }
    vTaskDelay(pdMS_TO_TICKS(100));
  }
}

// =============================================================
//  SETUP / LOOP
// =============================================================
void setup() {
  Con.begin(115200);
  Con.println("\nIniciando SHADOW BOT CONTROL...");
  // Si dice BROWNOUT: la placa se reinició porque el voltaje cayó (casi
  // siempre al arrancar los motores) -> problema de alimentación, no de código.
  Con.printf("Causa del ultimo reinicio: %s\n", resetReasonName());

  // Carga la inversión de motores guardada por la app (si nunca se guardó
  // nada, usa los defaults de arriba). "motors" es el namespace en NVS.
  // "motors2": se descartan las inversiones guardadas por firmwares
  // anteriores (con otro cableado volteaban una rueda y el carrito solo
  // giraba en lugar de avanzar). PRUEBA_BTS_SERVOS confirmó el sentido.
  motorPrefs.begin("motors2", false);
  motorAInverted = motorPrefs.getBool("aInv", MOTOR_A_INVERTED_DEFAULT);
  motorBInverted = motorPrefs.getBool("bInv", MOTOR_B_INVERTED_DEFAULT);
  Con.printf("Inversión motores -> A:%d B:%d\n", motorAInverted, motorBInverted);
  lcdLuz = motorPrefs.getBool("lcdLuz", true);    // luz del LCD como la dejó la app

#if LEDC_API_V3
  Con.println("LEDC: usando API core 3.x (ledcAttach por pin)");
  ledcAttach(MOTOR_A_RPWM, PWM_FREQ, PWM_RES);
  ledcAttach(MOTOR_A_LPWM, PWM_FREQ, PWM_RES);
  ledcAttach(MOTOR_B_RPWM, PWM_FREQ, PWM_RES);
  ledcAttach(MOTOR_B_LPWM, PWM_FREQ, PWM_RES);
#else
  Con.println("LEDC: usando API core 2.x (ledcSetup/ledcAttachPin por canal)");
  ledcSetup(CH_A_FWD, PWM_FREQ, PWM_RES); ledcAttachPin(MOTOR_A_RPWM, CH_A_FWD);
  ledcSetup(CH_A_BWD, PWM_FREQ, PWM_RES); ledcAttachPin(MOTOR_A_LPWM, CH_A_BWD);
  ledcSetup(CH_B_FWD, PWM_FREQ, PWM_RES); ledcAttachPin(MOTOR_B_RPWM, CH_B_FWD);
  ledcSetup(CH_B_BWD, PWM_FREQ, PWM_RES); ledcAttachPin(MOTOR_B_LPWM, CH_B_BWD);
#endif
  stopMotors();

  servoPan.setPeriodHertz(50);
  servoTilt.setPeriodHertz(50);
  servoPan.attach(SERVO_PAN_PIN, SERVO_MIN_US, SERVO_MAX_US);
  servoTilt.attach(SERVO_TILT_PIN, SERVO_MIN_US, SERVO_MAX_US);
  suavePan  = { &servoPan,  &panAngle,  (float)panAngle,  0, -1 };
  suaveTilt = { &servoTilt, &tiltAngle, (float)tiltAngle, 0, -1 };
  servoPaso(suavePan, 0, servoVmax, servoAcel);    // primer pulso: 90°
  servoPaso(suaveTilt, 0, servoVmax, servoAcel);
  xTaskCreatePinnedToCore(servoTask, "servoTask", 3072, NULL, 2, NULL, 1);
  // LCD 16x2: su propio task de baja prioridad (arranca antes del WiFi
  // para que la presentación salga apenas prende la placa).
  xTaskCreatePinnedToCore(lcdTask, "lcdTask", 4096, NULL, 1, NULL, 1);

  // La cola y el task de motores van ANTES del WiFi.
  moveQueue = xQueueCreate(1, sizeof(MoveCmd));
  // 4096: con 2048 el Con.printf de aplicarMovimiento quedaba al límite
  // de la pila; un desborde reinicia la placa a media maniobra.
  xTaskCreatePinnedToCore(motorTask, "motorTask", 4096, NULL, 1, NULL, 0);

  WiFi.begin(ssid, password);
  Con.print("Conectando WiFi");
  // Mientras conecta ya se puede usar el Monitor Serie (sin WiFi el
  // servidor no responde, pero motores y brazo sí, por Serie).
  while (WiFi.status() != WL_CONNECTED) {
    for (int i = 0; i < 50; i++) { serieTick(); delay(10); }
    Con.print(".");
  }
  WiFi.setSleep(false);   // sin esto el radio duerme entre paquetes y mete lag intermitente
  String localIP = WiFi.localIP().toString();
  Con.printf("\nIP: %s\n", localIP.c_str());
  // Su IP llega al bot de Telegram vía CAMARA (ver announceTick).

  server.on("/ping", handlePing);
  server.on("/move", handleMove);
  server.on("/movevec", handleMoveVec);
  server.on("/arm", handleArm);
  server.on("/armset", handleArmSet);
  server.on("/motorinvert", handleMotorInvert);
  server.on("/display", handleDisplay);
  server.on("/pad", handlePad);
  server.on("/modo", handleModo);
  server.on("/mode", handleMode);
  server.on("/telemetry", handleTelemetry);
  server.on("/", handleEstado);
  server.on("/baile", handleBaile);
  server.on("/estado", handleEstado);
  server.on("/lcd", handleLcd);
  server.onNotFound([]() { sendError(404, "not found"); });
  announceUdp.begin(ANNOUNCE_PORT);
  server.begin();
  Con.println("Servidor de control iniciado");
  serieAyuda();
}

// ---- Avisos de IP por UDP ----
// Cada 3 s: "SHADOWBOT-CONTROL" por broadcast (CAMARA lo oye y manda
// "IP CONTROL: x" al bot de Telegram). Y se escucha a SENSORES, que manda
// "SHADOWBOT-SENSORES <IP de CONTROL que tiene guardada>": si no es la de
// esta placa se la pasa por /controlip y el mando queda emparejado solo.
void announceTick() {
  unsigned long now = millis();
  if (now >= nextAnnounceMs && WiFi.status() == WL_CONNECTED) {
    nextAnnounceMs = now + 3000;
    announceUdp.beginPacket(IPAddress(255, 255, 255, 255), ANNOUNCE_PORT);
    announceUdp.print("SHADOWBOT-CONTROL");
    announceUdp.endPacket();
  }

  int len = announceUdp.parsePacket();
  if (len <= 0) return;
  char buf[64];
  int n = announceUdp.read(buf, sizeof(buf) - 1);
  buf[n > 0 ? n : 0] = 0;
  String msg(buf);
  if (!msg.startsWith("SHADOWBOT-SENSORES ")) return;
  String ip = announceUdp.remoteIP().toString();
  String suControl = msg.substring(19);
  suControl.trim();
  String miIp = WiFi.localIP().toString();
  if (suControl == miIp) return;
  // GET simple (sin HTTPClient: así no se enlaza nada de HTTPS).
  WiFiClient c;
  if (c.connect(ip.c_str(), 80, 400)) {
    c.print("GET /controlip?ip=" + miIp + " HTTP/1.1\r\nHost: " + ip + "\r\nConnection: close\r\n\r\n");
    c.setTimeout(400);
    String status = c.readStringUntil('\n');
    c.stop();
    Con.printf("SENSORES (%s) no tenia la IP de CONTROL -> /controlip %s\n", ip.c_str(), status.c_str());
  }
}

// =============================================================
//  COMANDOS POR MONITOR SERIE (mismos que PRUEBA_BTS_SERVOS)
// =============================================================
// Los motores pasan por la MISMA cola que la app (motorTask), con 3 s de
// watchdog en lugar de 800 ms. Los servos, por el mismo movimiento suave.
void serieMover(int l, int r) {
  MoveCmd cmd = {};
  cmd.raw = true;
  cmd.rawLeft  = (int16_t)constrain(l, -255, 255);
  cmd.rawRight = (int16_t)constrain(r, -255, 255);
  cmd.holdMs = 3000;
  xQueueOverwrite(moveQueue, &cmd);
}

void serieAyuda() {
  Con.println(
    "\nComandos (velocidad -255..255; los motores se paran solos a los 3 s):\n"
    "  a 150 | b -150 | ab 120   motor A (IZQ) / B (DER) / los dos\n"
    "  adelante 150 | atras | izq | der   el carrito completo\n"
    "  s  (o Enter)              PARAR\n"
    "  pan 90 | tilt 45          brazo (0..180), movimiento suave\n"
    "  centro | barrido          brazo a 90 / barrido completo suave\n"
    "  suave on|off              activa / quita el movimiento suave\n"
    "  vel 200 | acel 600        velocidad (grados/s) y aceleracion (grados/s2) del brazo\n"
    "  inv a | inv b             invierte el sentido de un motor (se guarda, igual que en la app)\n"
    "  lcd | luz on|off          estado del LCD 16x2 / prende o apaga su luz\n"
    "  estado | ?                valores actuales / esta ayuda\n");
}

void serieEstado() {
  Con.printf("\nModo: %s · WiFi: %s · IP: %s\n", modeName(),
             WiFi.status() == WL_CONNECTED ? "conectado" : "SIN CONEXION", WiFi.localIP().toString().c_str());
  Con.printf("Motores: izq %d · der %d · invertidos A:%s B:%s\n", (int)motorOutL, (int)motorOutR,
             motorAInverted ? "si" : "no", motorBInverted ? "si" : "no");
  Con.printf("Brazo: pan %d (va en %.1f) · tilt %d (va en %.1f)\n",
             (int)panAngle, suavePan.pos, (int)tiltAngle, suaveTilt.pos);
  Con.printf("Suave: %s · vel %.0f grados/s · acel %.0f grados/s2\n\n",
             servoSuave ? "SI" : "no", servoVmax, servoAcel);
}

// Espera a que el brazo llegue a su objetivo (o se cancele con una tecla).
bool serieEsperaBrazo(unsigned long maxMs) {
  unsigned long t0 = millis();
  while (millis() - t0 < maxMs) {
    if (Con.available()) { while (Con.available()) Con.read(); Con.println(">> barrido cancelado"); return false; }
    if (suavePan.pos == panAngle && suaveTilt.pos == tiltAngle) return true;
    server.handleClient();
    delay(10);
  }
  return true;
}

void serieComando(String line) {
  line.trim();
  line.toLowerCase();
  Con.printf("\n> %s\n", line.length() ? line.c_str() : "(Enter)");
  if (line.isEmpty() || line == "s" || line == "stop") { serieMover(0, 0); Con.println(">> PARADO"); return; }
  if (line == "?" || line == "ayuda") { serieAyuda(); return; }
  if (line == "estado") { serieEstado(); return; }
  if (line == "centro") { brazoA(90, 90); Con.println("Brazo -> 90 / 90"); return; }
  if (line == "lcd") {
    if (lcdAddr) Con.printf("LCD I2C OK en 0x%02X (SDA=GPIO%d SCL=GPIO%d). Si no ves letras, gira el potenciometro azul.\n",
                            lcdAddr, lcdSdaPin, lcdSclPin);
    else { Con.printf("LCD I2C NO encontrado: revisa VCC=5V, GND, SDA=GPIO%d, SCL=GPIO%d.\n", LCD_SDA, LCD_SCL);
           Con.println("(el diagnostico de pines sale solo cada ~1 min; tambien al reiniciar la placa)"); }
    return;
  }
  if (line == "barrido") {
    Con.println("Barrido suave: 0 -> 180 -> 90 (cualquier tecla lo cancela)");
    brazoA(0, 0);     if (!serieEsperaBrazo(5000)) return;
    brazoA(180, 180); if (!serieEsperaBrazo(5000)) return;
    brazoA(90, 90);   serieEsperaBrazo(5000);
    Con.println("Barrido terminado");
    return;
  }
  int sp = line.indexOf(' ');
  String cmd = sp < 0 ? line : line.substring(0, sp);
  String arg = sp < 0 ? "" : line.substring(sp + 1);
  arg.trim();
  int v = arg.toInt();

  if (cmd == "a" || cmd == "b" || cmd == "ab") {
    if (arg.isEmpty()) { Con.println("Falta la velocidad, ej: a 150"); return; }
    int l = cmd != "b" ? v : (int)motorOutL;
    int r = cmd != "a" ? v : (int)motorOutR;
    serieMover(l, r);
    Con.printf("Motores -> izq %d · der %d (3 s)\n", l, r);
    return;
  }
  if (cmd == "adelante" || cmd == "atras" || cmd == "izq" || cmd == "der") {
    int x = arg.isEmpty() ? 150 : constrain(abs(v), 0, 255);
    int l = x, r = x;
    if (cmd == "atras") { l = -x; r = -x; }
    if (cmd == "izq")   { l = -x; r =  x; }
    if (cmd == "der")   { l =  x; r = -x; }
    serieMover(l, r);
    Con.printf("Carrito: %s %d (3 s)\n", cmd.c_str(), x);
    return;
  }
  if (cmd == "pan" || cmd == "tilt") {
    if (arg.isEmpty()) { Con.println("Falta el angulo, ej: pan 90"); return; }
    if (cmd == "pan") brazoA(v, -1); else brazoA(-1, v);
    Con.printf("%s -> %d grados\n", cmd == "pan" ? "PAN" : "TILT", constrain(v, 0, 180));
    return;
  }
  if (cmd == "luz") {
    lcdLuz = (arg != "off");
    lcdSucio = true;                     // se reenvía todo con la luz nueva
    motorPrefs.putBool("lcdLuz", lcdLuz);
    Con.printf("Luz del LCD: %s\n", lcdLuz ? "ON" : "OFF");
    return;
  }
  if (cmd == "suave") {
    servoSuave = (arg != "off");
    Con.printf("Movimiento suave: %s\n", servoSuave ? "SI" : "NO (salta directo)");
    return;
  }
  if (cmd == "vel")  { servoVmax = constrain(v, 20, 1000);  Con.printf("Velocidad del brazo: %.0f grados/s\n", servoVmax); return; }
  if (cmd == "acel") { servoAcel = constrain(v, 50, 10000); Con.printf("Aceleracion del brazo: %.0f grados/s2\n", servoAcel); return; }
  if (cmd == "inv") {
    if (arg == "a")      { motorAInverted = !motorAInverted; motorPrefs.putBool("aInv", motorAInverted); }
    else if (arg == "b") { motorBInverted = !motorBInverted; motorPrefs.putBool("bInv", motorBInverted); }
    else { Con.println("Uso: inv a  o  inv b"); return; }
    serieMover(0, 0);
    Con.printf("Invertidos -> A:%s B:%s (guardado)\n", motorAInverted ? "si" : "no", motorBInverted ? "si" : "no");
    return;
  }
  Con.println("Comando no reconocido. Escribe ? para ver la ayuda.");
}

// Acepta cualquier fin de línea del Monitor Serie (o ninguno: 400 ms sin letras).
String serieBuf;
unsigned long serieUltimoRx = 0;
bool seriePrevCR = false;
void serieTick() {
  while (Con.available()) {
    char c = Con.read();
    serieUltimoRx = millis();
    if (c == '\n' && seriePrevCR) { seriePrevCR = false; continue; }
    seriePrevCR = (c == '\r');
    if (c == '\r' || c == '\n') { String l = serieBuf; serieBuf = ""; serieComando(l); }
    else if (serieBuf.length() < 40) serieBuf += c;
  }
  if (serieBuf.length() && millis() - serieUltimoRx > 400) { String l = serieBuf; serieBuf = ""; serieComando(l); }
}

void loop() {
  server.handleClient();
  announceTick();
  serieTick();
  // El movimiento y el watchdog ya no viven aquí: corren en motorTask
  // (core 0), así una petición HTTP lenta nunca los retrasa.
}
