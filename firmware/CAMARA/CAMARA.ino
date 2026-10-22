#include "esp_camera.h"
#include <WiFi.h>
#include <HTTPClient.h>
#include <WiFiClientSecure.h>
#include <WiFiUdp.h>             // oye los avisos de IP de CONTROL y SENSORES
#include "esp_http_server.h"
#include <ArduinoJson.h>
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"

// ── WiFi ──────────────────────────────────────────────
const char* ssid     = "TU_RED_WIFI";
const char* password = "TU_CONTRASENA_WIFI";

// ── Telegram ──────────────────────────────────────────
const char* BOT_TOKEN = "TU_TOKEN_DE_TELEGRAM";
const char* CHAT_ID   = "TU_CHAT_ID";   // tu chat_id numérico

// ── Pines ESP32-S3 CAM ────────────────────────────────
// Placa en el IDE: "ESP32S3 Dev Module" (PSRAM: "OPI PSRAM" si es N8R8/N16R8)
#define PWDN_GPIO_NUM     -1
#define RESET_GPIO_NUM    -1
#define XCLK_GPIO_NUM     15
#define SIOD_GPIO_NUM      4
#define SIOC_GPIO_NUM      5
#define Y9_GPIO_NUM       16
#define Y8_GPIO_NUM       17
#define Y7_GPIO_NUM       18
#define Y6_GPIO_NUM       12
#define Y5_GPIO_NUM       10
#define Y4_GPIO_NUM        8
#define Y3_GPIO_NUM        9
#define Y2_GPIO_NUM       11
#define VSYNC_GPIO_NUM     6
#define HREF_GPIO_NUM      7
#define PCLK_GPIO_NUM     13

// ── Dos servidores HTTP separados ─────────────────────
// El servidor httpd de ESP-IDF corre en UN solo hilo: si el handler de
// /stream nunca vuelve (su while(true) manda frames sin parar mientras
// el cliente siga conectado), ese hilo queda ocupado para siempre y
// /capture, /viewer, etc. no se pueden atender — el cliente se queda
// esperando o recibe una respuesta a medias/corrupta. Por eso /stream
// vive en su PROPIO servidor (puerto 81), igual que en el ejemplo oficial
// de Espressif (CameraWebServer): así "ver el video" y "tomar una foto"
// nunca compiten por el mismo hilo.
httpd_handle_t camera_httpd = NULL;   // puerto 80: index, viewer, capture
httpd_handle_t stream_httpd  = NULL;  // puerto 81: solo /stream
String localIP = "";
bool camOkGlobal = false;
esp_err_t camErr = ESP_OK;      // último error de esp_camera_init (0 = bien)
bool psramOk = false;

// El propio driver de la cámara solo debería atender un get/return de
// frame a la vez. Con dos servidores en dos hilos, /stream y /capture SÍ
// pueden llamar a esp_camera_fb_get()/esp_camera_fb_return() al mismo
// tiempo — este mutex evita que se pisen entre sí.
SemaphoreHandle_t camMutex;

// ── Enviar mensaje a Telegram ─────────────────────────
// HTTPS sin certificado (setInsecure): así no depende de la versión del
// core ni de que el certificado de Telegram cambie. Devuelve true si
// Telegram contestó 200; si no, quien llama lo reintenta más tarde.
bool sendTelegram(const String& msg) {
  if (WiFi.status() != WL_CONNECTED) {
    Serial.println("Telegram: sin WiFi, no se manda");
    return false;
  }
  WiFiClientSecure tls;
  tls.setInsecure();
  tls.setTimeout(8);

  HTTPClient http;
  String url = "https://api.telegram.org/bot";
  url += BOT_TOKEN;
  url += "/sendMessage";

  if (!http.begin(tls, url)) {
    Serial.println("Telegram: no se pudo abrir la conexión");
    return false;
  }
  http.setTimeout(8000);
  http.addHeader("Content-Type", "application/json");

  // Construcción segura del JSON (texto plano: sin Markdown, que rechaza
  // mensajes con "_" o "*" sueltos)
  StaticJsonDocument<256> doc;
  doc["chat_id"] = CHAT_ID;
  doc["text"]    = msg;

  String body;
  serializeJson(doc, body);

  int code = http.POST(body);
  if (code == 200) Serial.printf("Telegram OK: %s\n", msg.c_str());
  else Serial.printf("Telegram FALLÓ (HTTP %d): %s\n", code, code > 0 ? http.getString().c_str() : http.errorToString(code).c_str());
  http.end();
  return code == 200;
}

// Mensajes que no se pudieron mandar: se reintentan cada 10 s.
bool pendienteCamara = false;
bool pendienteControl = false, pendienteSensores = false;

// ── Avisos de IP de las otras placas (UDP) ──────────────
// CONTROL y SENSORES ya no usan Telegram (el HTTPS no les cabía en la
// partición por defecto): cada 3 s mandan por broadcast "SHADOWBOT-CONTROL"
// o "SHADOWBOT-SENSORES ...". Esta placa los oye y manda su IP al bot la
// primera vez (o si cambia). /ip responde con las 3.
WiFiUDP announceUdp;
const uint16_t ANNOUNCE_PORT = 4210;
String ipControl = "", ipSensores = "";

void announceTick() {
  for (int guard = 0; guard < 4; guard++) {          // vacía lo que llegó mientras Telegram bloqueaba
    int len = announceUdp.parsePacket();
    if (len <= 0) return;
    char buf[64];
    int n = announceUdp.read(buf, sizeof(buf) - 1);
    buf[n > 0 ? n : 0] = 0;
    String msg(buf);
    String ip = announceUdp.remoteIP().toString();
    if (msg.startsWith("SHADOWBOT-CONTROL") && ip != ipControl) {
      ipControl = ip;
      Serial.printf("Aviso de CONTROL: %s\n", ip.c_str());
      pendienteControl = !sendTelegram("IP CONTROL: " + ip);
    } else if (msg.startsWith("SHADOWBOT-SENSORES") && ip != ipSensores) {
      ipSensores = ip;
      Serial.printf("Aviso de SENSORES: %s\n", ip.c_str());
      pendienteSensores = !sendTelegram("IP SENSORES: " + ip);
    }
  }
}

// ── Polling: escucha comandos del bot ─────────────────
long lastUpdateId = 0;   // evita procesar el mismo mensaje dos veces

void checkTelegram() {
  bool pedirIps = false;
  if (WiFi.status() != WL_CONNECTED) return;

  WiFiClientSecure tls;
  tls.setInsecure();
  tls.setTimeout(8);
  HTTPClient http;
  String url = "https://api.telegram.org/bot";
  url += BOT_TOKEN;
  url += "/getUpdates?timeout=3&offset=";
  url += (lastUpdateId + 1);

  if (!http.begin(tls, url)) return;
  http.setTimeout(8000);
  int code = http.GET();

  if (code == 200) {
    String payload = http.getString();

    DynamicJsonDocument doc(2048);
    if (deserializeJson(doc, payload) == DeserializationError::Ok) {
      JsonArray results = doc["result"].as<JsonArray>();

      for (JsonObject upd : results) {
        long id = upd["update_id"].as<long>();
        if (id > lastUpdateId) lastUpdateId = id;

        // Solo mensajes de texto
        if (!upd.containsKey("message")) continue;
        String text = upd["message"]["text"] | "";
        // chat.id es un NÚMERO en el JSON de Telegram, no un string — leerlo
        // con "| \"\"" (como arriba con el texto) siempre daba "" porque
        // ArduinoJson solo usa el default de "|" cuando el tipo no calza, y
        // nunca respondía a /ip ni /start. Además el chat_id de este bot
        // (un número de 10 dígitos) no cabe en un long de 32 bits (se desborda), así que
        // hace falta long long para leerlo y compararlo bien.
        long long from_id = upd["message"]["chat"]["id"] | 0LL;

        // Seguridad: solo responde a tu chat_id
        if (from_id != atoll(CHAT_ID)) continue;

        if (text == "/ip" || text == "/start") {
          pedirIps = true;   // se contesta al cerrar esta consulta (una conexión HTTPS a la vez)
        }
      }
    }
  }
  http.end();
  if (pedirIps) {
    sendTelegram("IP CAMARA: " + localIP +
                 (camOkGlobal ? String("  (video OK)") : String("  (ERROR: cámara no iniciada 0x") + String((unsigned)camErr, HEX) + ")") +
                 "\nIP CONTROL: " + (ipControl.isEmpty() ? String("(sin aviso)") : ipControl) +
                 "\nIP SENSORES: " + (ipSensores.isEmpty() ? String("(sin aviso)") : ipSensores));
  }
}

// ================= HTML pages (sin cambios) ===========
static const char PROGMEM INDEX_HTML[] = R"rawliteral(
<!DOCTYPE html><html lang="es"><head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1.0">
<title>INSPECT-BOT</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{background:#0a0a0a;display:flex;flex-direction:column;align-items:center;
     justify-content:center;min-height:100vh;font-family:'Segoe UI',sans-serif;gap:32px}
.logo{font-size:5rem;animation:pulse 2s infinite}
@keyframes pulse{0%,100%{transform:scale(1);opacity:1}50%{transform:scale(1.1);opacity:.7}}
h1{font-size:1.4rem;color:#00e5ff;letter-spacing:3px;text-transform:uppercase;text-align:center}
p{font-size:.85rem;color:#444;letter-spacing:1px}
#btn-iniciar{padding:18px 60px;font-size:1.1rem;font-weight:bold;letter-spacing:2px;
  text-transform:uppercase;border:none;border-radius:50px;cursor:pointer;
  background:linear-gradient(135deg,#ff0000,#990000);color:#000;text-decoration:none;
  box-shadow:0 0 30px #00e5ff44;transition:all .3s}
#btn-iniciar:hover{box-shadow:0 0 50px #00e5ffaa;transform:scale(1.05)}
.dot-row{display:flex;gap:8px}
.dot{width:8px;height:8px;border-radius:50%;background:#00e5ff22;animation:blink 1.4s infinite}
.dot:nth-child(2){animation-delay:.2s}.dot:nth-child(3){animation-delay:.4s}
@keyframes blink{0%,100%{background:#00e5ff22}50%{background:#00e5ff}}
</style></head><body>
<div class="logo">📷</div>
<h1>INSPECT-BOT</h1>
<div class="dot-row"><div class="dot"></div><div class="dot"></div><div class="dot"></div></div>
<a id="btn-iniciar" href="/viewer">▶ Iniciar Video</a>
<p>ESP32-S3 · Streaming en vivo</p>
</body></html>
)rawliteral";

static const char PROGMEM VIEWER_HTML[] = R"rawliteral(
<!DOCTYPE html><html lang="es"><head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0">
<title>Stream · ESP32-S3</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{background:#000;display:flex;flex-direction:column;align-items:center;
     justify-content:center;min-height:100vh;font-family:'Segoe UI',sans-serif}
#top-bar{width:100%;max-width:720px;display:flex;align-items:center;
  justify-content:space-between;padding:10px 16px;background:#111;
  border-bottom:1px solid #00e5ff22}
#live-badge{display:flex;align-items:center;gap:8px;font-size:.82rem;
  color:#00e5ff;letter-spacing:1px}
#dot{width:10px;height:10px;border-radius:50%;background:#333;transition:background .3s}
#dot.live{background:#00ff88;box-shadow:0 0 8px #00ff88}
#dot.err{background:#ff4444;box-shadow:0 0 8px #ff4444}
#btn-back{font-size:.78rem;color:#aaa;background:none;border:1px solid #333;
  padding:5px 14px;border-radius:20px;cursor:pointer;text-decoration:none;transition:all .2s}
#btn-back:hover{border-color:#00e5ff;color:#00e5ff}
#stream-wrap{width:100%;max-width:720px;background:#000;display:flex;
  align-items:center;justify-content:center;position:relative;min-height:240px}
#stream{width:100%;max-width:720px;display:block}
#loading{position:absolute;top:50%;left:50%;transform:translate(-50%,-50%);
  text-align:center;color:#333;font-size:.85rem}
#loading .spin{font-size:2.5rem;display:block;animation:spin 1.5s linear infinite;margin-bottom:10px}
@keyframes spin{to{transform:rotate(360deg)}}
#bottom-bar{width:100%;max-width:720px;display:flex;align-items:center;
  justify-content:space-between;padding:10px 16px;background:#111;
  border-top:1px solid #00e5ff22}
#fps-label{font-size:.75rem;color:#444}
#btn-capture{padding:7px 20px;font-size:.82rem;font-weight:bold;
  background:linear-gradient(135deg,#00e5ff,#0077ff);color:#000;border:none;
  border-radius:20px;cursor:pointer;transition:opacity .2s}
#btn-capture:hover{opacity:.8}
#btn-fs{font-size:.78rem;color:#aaa;background:none;border:1px solid #333;
  padding:5px 14px;border-radius:20px;cursor:pointer;transition:all .2s}
#btn-fs:hover{border-color:#00e5ff;color:#00e5ff}
</style></head><body>
<div id="top-bar">
  <div id="live-badge"><div id="dot"></div><span id="status-text">Conectando...</span></div>
  <a id="btn-back" href="/">← Volver</a>
</div>
<div id="stream-wrap">
  <div id="loading"><span class="spin">⏳</span>Cargando stream...</div>
  <img id="stream" src="" alt="stream">
</div>
<div id="bottom-bar">
  <span id="fps-label">— fps</span>
  <button id="btn-capture" onclick="capturar()">📸 Capturar</button>
  <button id="btn-fs" onclick="pantallaCompleta()">⛶ Pantalla completa</button>
</div>
<script>
const img=document.getElementById('stream'),dot=document.getElementById('dot'),
  stText=document.getElementById('status-text'),loading=document.getElementById('loading'),
  fpsLabel=document.getElementById('fps-label');
let frameCount=0,lastTime=Date.now(),retryTimer=null;
function iniciarStream(){img.src='http://'+location.hostname+':81/stream?'+Date.now();}
img.onload=()=>{
  loading.style.display='none';dot.className='live';stText.textContent='🔴 EN VIVO';
  frameCount++;const now=Date.now();
  if(now-lastTime>=2000){fpsLabel.textContent='~'+(frameCount/((now-lastTime)/1000)).toFixed(1)+' fps';
    frameCount=0;lastTime=now;}
};
img.onerror=()=>{
  dot.className='err';stText.textContent='⚠ Sin señal — reintentando...';
  loading.style.display='block';clearTimeout(retryTimer);retryTimer=setTimeout(iniciarStream,3000);
};
function capturar(){const a=document.createElement('a');a.href='/capture';
  a.download='foto_'+Date.now()+'.jpg';a.click();}
function pantallaCompleta(){const el=document.getElementById('stream-wrap');
  if(!document.fullscreenElement)el.requestFullscreen().catch(e=>console.warn(e));
  else document.exitFullscreen();}
iniciarStream();
</script>
</body></html>
)rawliteral";

// ================= HANDLERS ===================
static esp_err_t index_handler(httpd_req_t *req) {
  httpd_resp_set_type(req, "text/html");
  return httpd_resp_send(req, INDEX_HTML, strlen(INDEX_HTML));
}
static esp_err_t viewer_handler(httpd_req_t *req) {
  httpd_resp_set_type(req, "text/html");
  return httpd_resp_send(req, VIEWER_HTML, strlen(VIEWER_HTML));
}
static esp_err_t stream_handler(httpd_req_t *req) {
  if (!camOkGlobal) {
    httpd_resp_set_status(req, "503 Service Unavailable");
    httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
    return httpd_resp_sendstr(req, "camara no iniciada");
  }
  camera_fb_t *fb = NULL;
  esp_err_t res   = ESP_OK;
  char part_buf[64];
  int fallos = 0;
  httpd_resp_set_type(req, "multipart/x-mixed-replace;boundary=frame");
  httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
  httpd_resp_set_hdr(req, "Cache-Control", "no-cache");
  while (true) {
    xSemaphoreTake(camMutex, portMAX_DELAY);
    fb = esp_camera_fb_get();
    xSemaphoreGive(camMutex);
    if (!fb) {                       // un frame perdido no corta el video
      if (++fallos > 20) { res = ESP_FAIL; break; }
      vTaskDelay(pdMS_TO_TICKS(30));
      continue;
    }
    fallos = 0;
    size_t hlen = snprintf(part_buf, sizeof(part_buf),
      "--frame\r\nContent-Type: image/jpeg\r\nContent-Length: %zu\r\n\r\n", fb->len);
    res = httpd_resp_send_chunk(req, part_buf, hlen);
    if (res == ESP_OK) res = httpd_resp_send_chunk(req, (const char*)fb->buf, fb->len);
    if (res == ESP_OK) res = httpd_resp_send_chunk(req, "\r\n", 2);
    esp_camera_fb_return(fb);
    if (res != ESP_OK) break;
  }
  return res;
}
// Estado de la cámara para la app ("Probar conexión"):
//   {"cam":true,"err":"0x0","psram":true,"ip":"...","up":123}
static esp_err_t estado_handler(httpd_req_t *req) {
  char buf[160];
  snprintf(buf, sizeof(buf), "{\"cam\":%s,\"err\":\"0x%x\",\"psram\":%s,\"ip\":\"%s\",\"up\":%lu}",
           camOkGlobal ? "true" : "false", (unsigned)camErr, psramOk ? "true" : "false",
           localIP.c_str(), millis() / 1000);
  httpd_resp_set_type(req, "application/json");
  httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
  return httpd_resp_sendstr(req, buf);
}
static esp_err_t capture_handler(httpd_req_t *req) {
  if (!camOkGlobal) { httpd_resp_send_500(req); return ESP_FAIL; }
  xSemaphoreTake(camMutex, portMAX_DELAY);
  camera_fb_t *fb = esp_camera_fb_get();
  xSemaphoreGive(camMutex);
  if (!fb) { httpd_resp_send_500(req); return ESP_FAIL; }
  httpd_resp_set_type(req, "image/jpeg");
  httpd_resp_set_hdr(req, "Content-Disposition", "attachment; filename=capture.jpg");
  httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
  httpd_resp_send(req, (const char*)fb->buf, fb->len);
  esp_camera_fb_return(fb);
  return ESP_OK;
}

// ================= SERVER =====================
void startCameraServer() {
  // Servidor principal (puerto 80): index/viewer/capture. Nunca se queda
  // pegado esperando (cada handler responde y vuelve), así /capture
  // siempre se atiende al toque, exista o no un cliente viendo el stream.
  httpd_config_t config   = HTTPD_DEFAULT_CONFIG();
  config.server_port      = 80;
  config.ctrl_port        = 32768;
  config.max_uri_handlers = 8;
  config.lru_purge_enable = true;      // conexiones viejas de la app no tapan las nuevas
  httpd_uri_t index_uri   = { "/",        HTTP_GET, index_handler,   NULL };
  httpd_uri_t estado_uri  = { "/estado",  HTTP_GET, estado_handler,  NULL };
  httpd_uri_t viewer_uri  = { "/viewer",  HTTP_GET, viewer_handler,  NULL };
  httpd_uri_t capture_uri = { "/capture", HTTP_GET, capture_handler, NULL };
  if (httpd_start(&camera_httpd, &config) == ESP_OK) {
    httpd_register_uri_handler(camera_httpd, &index_uri);
    httpd_register_uri_handler(camera_httpd, &viewer_uri);
    httpd_register_uri_handler(camera_httpd, &capture_uri);
    httpd_register_uri_handler(camera_httpd, &estado_uri);
    Serial.println("Servidor principal iniciado (puerto 80)");
  }

  // Servidor del stream (puerto 81): SOLO /stream. Su handler nunca
  // vuelve mientras el cliente siga conectado — al estar aislado en su
  // propio servidor/hilo, ya no bloquea nada del puerto 80.
  httpd_config_t stream_config   = HTTPD_DEFAULT_CONFIG();
  stream_config.server_port      = 81;
  stream_config.ctrl_port        = 32769;
  stream_config.max_uri_handlers = 1;
  stream_config.lru_purge_enable = true; // si la app se reconecta, suelta el stream viejo
  httpd_uri_t stream_uri = { "/stream", HTTP_GET, stream_handler, NULL };
  if (httpd_start(&stream_httpd, &stream_config) == ESP_OK) {
    httpd_register_uri_handler(stream_httpd, &stream_uri);
    Serial.println("Servidor de stream iniciado (puerto 81)");
  }
}

// ================= SETUP ======================
void setup() {
  Serial.begin(115200);
  Serial.println("\nIniciando INSPECT-BOT...");

  bool psram = psramFound();
  psramOk = psram;
  Serial.println(psram ? "PSRAM: OK" : "PSRAM: NO encontrada");

  camera_config_t config;
  config.ledc_channel = LEDC_CHANNEL_0;
  config.ledc_timer   = LEDC_TIMER_0;
  config.pin_d0 = Y2_GPIO_NUM; config.pin_d1 = Y3_GPIO_NUM;
  config.pin_d2 = Y4_GPIO_NUM; config.pin_d3 = Y5_GPIO_NUM;
  config.pin_d4 = Y6_GPIO_NUM; config.pin_d5 = Y7_GPIO_NUM;
  config.pin_d6 = Y8_GPIO_NUM; config.pin_d7 = Y9_GPIO_NUM;
  config.pin_xclk     = XCLK_GPIO_NUM;
  config.pin_pclk     = PCLK_GPIO_NUM;
  config.pin_vsync    = VSYNC_GPIO_NUM;
  config.pin_href     = HREF_GPIO_NUM;
  config.pin_sccb_sda = SIOD_GPIO_NUM;
  config.pin_sccb_scl = SIOC_GPIO_NUM;
  config.pin_pwdn     = PWDN_GPIO_NUM;
  config.pin_reset    = RESET_GPIO_NUM;
  config.xclk_freq_hz = 10000000;
  config.pixel_format = PIXFORMAT_JPEG;
  config.frame_size   = FRAMESIZE_QVGA;
  config.jpeg_quality = 15;
  // Con PSRAM, 2 buffers: mientras uno se manda por /stream o /capture, la
  // cámara ya puede ir llenando el otro en vez de esperar — reduce las
  // esperas cuando el stream y una captura piden frame casi al mismo tiempo.
  config.fb_count     = psram ? 2 : 1;
  config.fb_location  = psram ? CAMERA_FB_IN_PSRAM : CAMERA_FB_IN_DRAM;
  config.grab_mode    = CAMERA_GRAB_WHEN_EMPTY;

  // Si la cámara falla, la placa SIGUE: se conecta al WiFi y avisa por
  // Telegram (antes se salía aquí y no llegaba ninguna IP al bot).
  // Hasta 4 intentos: a 10 MHz y luego a 20 MHz (algunos sensores solo
  // arrancan con uno de los dos), soltando el driver entre intentos.
  bool camOk = false;
  const int relojes[] = {10000000, 10000000, 20000000, 20000000};
  for (int i = 0; i < 4 && !camOk; i++) {
    config.xclk_freq_hz = relojes[i];
    camErr = esp_camera_init(&config);
    camOk = camErr == ESP_OK;
    if (!camOk) {
      Serial.printf("Camara: intento %d falló (0x%x) a %d MHz\n", i + 1, (unsigned)camErr, relojes[i] / 1000000);
      esp_camera_deinit();
      delay(400);
    }
  }
  camOkGlobal = camOk;
  if (camOk) {
    sensor_t *s = esp_camera_sensor_get();
    s->set_brightness(s, 0); s->set_contrast(s, 0); s->set_saturation(s, 0);
    s->set_whitebal(s, 1);   s->set_hmirror(s, 0);  s->set_vflip(s, 0);
    Serial.println("Camara: OK");
  } else {
    Serial.println("ERROR: cámara no iniciada (revisa el flex de la cámara). Sigo con WiFi y Telegram.");
  }

  camMutex = xSemaphoreCreateMutex();

  WiFi.begin(ssid, password);
  Serial.print("Conectando WiFi");
  while (WiFi.status() != WL_CONNECTED) { delay(500); Serial.print("."); }

  localIP = WiFi.localIP().toString();
  Serial.printf("\nIP: %s\n", localIP.c_str());

  startCameraServer();
  announceUdp.begin(ANNOUNCE_PORT);

  // ── Notificación automática al arrancar ──────────────
  camOkGlobal = camOk;
  if (!camOk) Serial.printf("ERROR cámara 0x%x: revisa el flex (contactos hacia la placa, seguro cerrado) y PSRAM \"OPI PSRAM\" en el IDE\n", (unsigned)camErr);
  pendienteCamara = !sendTelegram(String("IP CAMARA: ") + localIP + (camOk ? "" : "  (ERROR: cámara no iniciada)"));
}

// ================= LOOP =======================
unsigned long lastCheck = 0;

unsigned long lastRetry = 0;

void loop() {
  announceTick();
  // Reintenta lo que no se pudo mandar (Telegram caído, WiFi lento al arrancar…)
  if (millis() - lastRetry > 10000) {
    lastRetry = millis();
    if (WiFi.status() != WL_CONNECTED) {
      Serial.println("WiFi perdido, reconectando...");
      WiFi.reconnect();
    } else {
      if (localIP != WiFi.localIP().toString()) { localIP = WiFi.localIP().toString(); pendienteCamara = true; }
      if (pendienteCamara)   pendienteCamara   = !sendTelegram(String("IP CAMARA: ") + localIP + (camOkGlobal ? "" : "  (ERROR: cámara no iniciada)"));
      if (pendienteControl)  pendienteControl  = !sendTelegram("IP CONTROL: " + ipControl);
      if (pendienteSensores) pendienteSensores = !sendTelegram("IP SENSORES: " + ipSensores);
    }
  }
  // Polling cada 5 segundos (no bloquea el stream)
  if (millis() - lastCheck > 5000) {
    lastCheck = millis();
    checkTelegram();
  }
  delay(1);
}