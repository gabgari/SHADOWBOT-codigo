// =========================================================
//  SHADOW BOT · ESP8266 "SENSORES"
//  1x MQ-2 (gas/humo) en A0 + 4 LEDs.  SIN mando de PS4.
//
//  Es la placa de sensores del proyecto (3 placas: ESP8266 SENSORES,
//  ESP32-S3 CONTROL y ESP32-S3 CAM). Habla la misma API HTTP con la app y
//  con CONTROL. No hay mando: todo (modos, bailes, manejo, brazo) se hace
//  desde la app (panel MODOS de la consola).
//
//  Arduino IDE:
//    Placa: "NodeMCU 1.0 (ESP-12E Module)" o "LOLIN(WEMOS) D1 mini"
//    (paquete esp8266 de ESP8266 Community). Opciones por defecto.
//    No necesita librerías extra.
//
//  Conexiones (NodeMCU / Wemos D1 mini):
//    MQ-2  VCC -> VIN (5V)    GND -> GND
//    MQ-2  AOUT -> divisor -> A0     (el A0 de estas placas acepta 0-3.3V)
//
//        AOUT_MQ2 ---[ 10k ]---+---[ 20k ]--- GND
//                              |
//                              A0
//
//    *** Si usas un módulo ESP-12 "pelón" (sin placa NodeMCU/D1 mini), su
//    A0 solo acepta 0-1V: el divisor tiene que ser 47k arriba / 10k abajo. ***
//
//    4 LEDs en 4 pines SEGUIDOS (D5·D6·D7·D8, igual en NodeMCU y D1 mini):
//    LED1 -> D5 (GPIO14)  LED2 -> D6 (GPIO12)
//    LED3 -> D7 (GPIO13)  LED4 -> D8 (GPIO15)
//    (cada LED con su resistencia de 220-330 Ω a GND)
//    D8 debe estar en LOW al arrancar: el LED con su resistencia a GND no
//    lo cambia (la placa ya trae 10k a GND), así que arranca normal.
//    Se evitan D3/D4 (deciden cómo arranca la placa) y D0.
//
//  API:
//    GET /sensors                         -> {"mq2":x}
//    GET /led?n=<1-4|all>&state=on|off    -> LEDs
//    GET /ledseq?n=<1-4>&linked=<0|1>     -> excluye/incluye un LED del barrido
//    GET /ledseq?active=<0|1>             -> arranca/detiene el barrido
//    GET /controlip?ip=<host>             -> guarda la IP de CONTROL (EEPROM)
//    GET /controlip                       -> devuelve la IP guardada
//    GET /ping                            -> "OK"
//  Además:
//    - cada 500 ms manda MQ-2 a CONTROL (/telemetry); CONTROL ya no tiene
//      pantalla, solo lo recibe (así nada cambia en la comunicación);
//    - cada 3 s avisa su IP por UDP ("SHADOWBOT-SENSORES ..."): CAMARA la
//      manda al bot de Telegram y CONTROL le pasa su propia IP.
// =========================================================
#include <ESP8266WiFi.h>
#include <ESP8266WebServer.h>
#include <WiFiUdp.h>
#include <EEPROM.h>

// ── WiFi (misma red que cámara y control) ────────────────
const char* ssid     = "TU_RED_WIFI";
const char* password = "TU_CONTRASENA_WIFI";

// ── Pines ────────────────────────────────────────────────
#define MQ2_PIN A0
// Números de GPIO directos (D5=14, D6=12, D7=13, D8=15) para que compile con
// cualquier placa ESP8266 elegida en el IDE, no solo NodeMCU/D1 mini.
const int ledPins[4] = {14, 12, 13, 15};

ESP8266WebServer server(80);

// ── Aviso de IP por UDP ──────────────────────────────────
WiFiUDP announceUdp;
const uint16_t ANNOUNCE_PORT = 4210;
unsigned long nextAnnounceMs = 0;

// =============================================================
//  MQ-2
// =============================================================
// 0-100 (%). El ADC de la ESP8266 es de 10 bits (0-1023). Leer A0 muy
// seguido estorba al WiFi en esta placa: se lee como mucho cada 200 ms y
// se reutiliza el último valor.
float mq2Pct = 0;
unsigned long mq2LastRead = 0;

float leerMq2Porcentaje() {
  unsigned long now = millis();
  if (mq2LastRead == 0 || now - mq2LastRead >= 200) {
    mq2LastRead = now;
    mq2Pct = constrain(analogRead(MQ2_PIN) * 100.0f / 1023.0f, 0.0f, 100.0f);
  }
  return mq2Pct;
}

// =============================================================
//  LEDs + barrido "auto increíble" (mismo comportamiento que el ESP32)
// =============================================================
void setLed(int idx, bool on) { digitalWrite(ledPins[idx], on ? HIGH : LOW); }

enum SeqPhase { SEQ_CHASE, SEQ_READY, SEQ_IDLE };
bool ledLinked[4]         = {false, false, false, false};
bool seqActive            = true;
SeqPhase seqPhase         = SEQ_CHASE;
int  seqPos               = -1;
unsigned long seqLastStep = 0;
const unsigned long SEQ_STEP_MS = 130;
const unsigned long SEQ_GAP_MS  = 220;

void seqApply() {
  for (int i = 0; i < 4; i++) setLed(i, (!ledLinked[i]) && (i == seqPos));
}

int seqNextPos(int cur) {
  for (int i = cur + 1; i <= 3; i++) if (!ledLinked[i]) return i;
  return -1;
}

struct SeqStep { uint8_t mask; unsigned long ms; };
const SeqStep READY_SCRIPT[] = {
  {0b0001, SEQ_STEP_MS}, {0b0010, SEQ_STEP_MS}, {0b0100, SEQ_STEP_MS}, {0b1000, SEQ_STEP_MS}, {0b0000, SEQ_GAP_MS},
  {0b0001, SEQ_STEP_MS}, {0b0010, SEQ_STEP_MS}, {0b0100, SEQ_STEP_MS}, {0b1000, SEQ_STEP_MS}, {0b0000, SEQ_GAP_MS},
  {0b1111, 180}, {0b0000, 180}, {0b1111, 180}, {0b0000, 180},
};
const int READY_SCRIPT_LEN = sizeof(READY_SCRIPT) / sizeof(READY_SCRIPT[0]);
int readyIdx = 0;
unsigned long readyLastStep = 0;

void readyApply() {
  uint8_t mask = READY_SCRIPT[readyIdx].mask;
  for (int i = 0; i < 4; i++) setLed(i, (mask >> i) & 1);
}

void startReadyAnimation() {
  seqPhase = SEQ_READY;
  readyIdx = 0;
  readyLastStep = millis();
  readyApply();
}

void seqTick() {
  if (!seqActive) return;
  unsigned long now = millis();
  if (seqPhase == SEQ_CHASE) {
    unsigned long d = (seqPos == -1) ? SEQ_GAP_MS : SEQ_STEP_MS;
    if (now - seqLastStep < d) return;
    seqLastStep = now;
    seqPos = seqNextPos(seqPos);
    seqApply();
  } else if (seqPhase == SEQ_READY) {
    if (now - readyLastStep < READY_SCRIPT[readyIdx].ms) return;
    readyLastStep = now;
    if (++readyIdx >= READY_SCRIPT_LEN) {
      for (int i = 0; i < 4; i++) setLed(i, false);
      seqPhase = SEQ_IDLE;
      return;
    }
    readyApply();
  }
}

// =============================================================
//  IP de CONTROL (EEPROM: sobrevive a reinicios)
// =============================================================
// La manda la app (o CONTROL solo, al oír el aviso UDP). Se usa para
// mandarle el MQ-2 (/telemetry).
String controlIp = "";
const int EE_SIZE = 72, EE_MAGIC = 0xB7;

void loadControlIp() {
  EEPROM.begin(EE_SIZE);
  if (EEPROM.read(0) == EE_MAGIC) {
    char buf[65];
    for (int i = 0; i < 64; i++) buf[i] = EEPROM.read(1 + i);
    buf[64] = 0;
    controlIp = String(buf);
  }
  Serial.println(controlIp.length() ? "IP de CONTROL guardada: " + controlIp : String("IP de CONTROL: (ninguna)"));
}

void saveControlIp(const String& ip) {
  controlIp = ip;
  EEPROM.write(0, EE_MAGIC);
  for (int i = 0; i < 64; i++) EEPROM.write(1 + i, i < (int)ip.length() ? ip[i] : 0);
  EEPROM.commit();
  Serial.println("IP de CONTROL actualizada: " + (ip.length() ? ip : String("(borrada)")));
}

// GET mínimo a CONTROL. Devuelve el código HTTP o -1.
int controlGet(const String& path, uint16_t timeoutMs) {
  if (WiFi.status() != WL_CONNECTED || controlIp.length() == 0) return -1;
  WiFiClient c;
  c.setTimeout(timeoutMs);
  if (!c.connect(controlIp.c_str(), 80)) return -1;
  c.print(String("GET ") + path + " HTTP/1.1\r\nHost: " + controlIp + "\r\nConnection: close\r\n\r\n");
  String status = c.readStringUntil('\n');
  c.stop();
  return status.length() >= 12 ? status.substring(9, 12).toInt() : -1;
}

// MQ-2 -> CONTROL cada 500 ms (si no responde, reintenta en 3 s).
unsigned long nextTelemetryMs = 0;
void telemetryTick() {
  unsigned long now = millis();
  if (now < nextTelemetryMs) return;
  if (WiFi.status() != WL_CONNECTED || controlIp.length() == 0) { nextTelemetryMs = now + 1000; return; }
  int code = controlGet("/telemetry?mq2=" + String(leerMq2Porcentaje(), 1), 200);
  nextTelemetryMs = now + (code == 200 ? 500 : 3000);
}

void announceTick() {
  unsigned long now = millis();
  if (now < nextAnnounceMs || WiFi.status() != WL_CONNECTED) return;
  nextAnnounceMs = now + 3000;
  announceUdp.beginPacket(IPAddress(255, 255, 255, 255), ANNOUNCE_PORT);
  announceUdp.print(String("SHADOWBOT-SENSORES ") + (controlIp.length() ? controlIp : String("-")));
  announceUdp.endPacket();
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

void handleSensors() {
  String json = "{\"mq2\":" + String(leerMq2Porcentaje(), 1) + "}";
  server.sendHeader("Access-Control-Allow-Origin", "*");
  server.send(200, "application/json", json);
}

void handleLed() {
  if (!server.hasArg("state")) { sendError(400, "falta state"); return; }
  String state = server.arg("state");
  bool on;
  if (state == "on") on = true;
  else if (state == "off") on = false;
  else { sendError(400, "state debe ser on|off"); return; }
  String n = server.hasArg("n") ? server.arg("n") : "all";
  if (n == "all") {
    for (int i = 0; i < 4; i++) setLed(i, on);
  } else {
    int idx = n.toInt() - 1;
    if (idx < 0 || idx > 3) { sendError(400, "n debe ser 1-4 o 'all'"); return; }
    setLed(idx, on);
  }
  sendOk();
}

void handleLedSeq() {
  if (server.hasArg("active")) {
    seqActive = server.arg("active").toInt() != 0;
    if (seqActive) { seqPhase = SEQ_CHASE; seqPos = -1; seqLastStep = millis(); }
  }
  if (server.hasArg("n")) {
    if (!server.hasArg("linked")) { sendError(400, "falta linked"); return; }
    int idx = server.arg("n").toInt() - 1;
    if (idx < 0 || idx > 3) { sendError(400, "n debe ser 1-4"); return; }
    ledLinked[idx] = server.arg("linked").toInt() != 0;
    if (seqActive) {
      bool allLinked = ledLinked[0] && ledLinked[1] && ledLinked[2] && ledLinked[3];
      if (allLinked && seqPhase == SEQ_CHASE) startReadyAnimation();
      else if (!allLinked && seqPhase != SEQ_CHASE) { seqPhase = SEQ_CHASE; seqPos = -1; seqLastStep = millis(); }
      else if (seqPhase == SEQ_CHASE) seqApply();
    }
  }
  sendOk();
}

void handleControlIp() {
  if (!server.hasArg("ip")) { sendOk(controlIp); return; }
  String ip = server.arg("ip");
  ip.trim();
  if (ip.length() > 64 || ip.indexOf(' ') >= 0 || ip.indexOf('/') >= 0) { sendError(400, "ip invalida"); return; }
  if (ip != controlIp) saveControlIp(ip);
  sendOk(controlIp);
}

// =============================================================
//  SETUP / LOOP
// =============================================================
void setup() {
  Serial.begin(115200);
  Serial.println("\nIniciando SHADOW BOT SENSORES (ESP8266: MQ-2 + 4 LEDs)...");
  for (int i = 0; i < 4; i++) { pinMode(ledPins[i], OUTPUT); setLed(i, false); }
  loadControlIp();

  WiFi.mode(WIFI_STA);
  WiFi.setSleepMode(WIFI_NONE_SLEEP);   // sin esto responde con lag intermitente
  WiFi.begin(ssid, password);
  Serial.print("Conectando WiFi");
  unsigned long wifiStart = millis();
  while (WiFi.status() != WL_CONNECTED) {
    delay(500);
    Serial.print(".");
    if (millis() - wifiStart > 20000) { Serial.println("\nWiFi no conectó — reiniciando..."); ESP.restart(); }
  }
  Serial.print("\nIP: ");
  Serial.println(WiFi.localIP());

  for (int i = 0; i < 2; i++) {          // "ya estoy en la red": 2 parpadeos
    for (int j = 0; j < 4; j++) setLed(j, true);
    delay(200);
    for (int j = 0; j < 4; j++) setLed(j, false);
    delay(200);
  }
  seqPhase = SEQ_CHASE; seqPos = -1; seqLastStep = millis();

  server.on("/ping", handlePing);
  server.on("/sensors", handleSensors);
  server.on("/led", handleLed);
  server.on("/ledseq", handleLedSeq);
  server.on("/controlip", handleControlIp);
  server.onNotFound([]() { sendError(404, "not found"); });
  server.begin();
  Serial.println("Servidor de sensores iniciado");
}

void loop() {
  server.handleClient();
  seqTick();
  telemetryTick();
  announceTick();
}
