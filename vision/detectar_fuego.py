"""Vision del robot de inspeccion y seguridad (camara Tapo C110 por RTSP). Plug and play.

Detecta, segun el modo:
    fuego       -> solo fuego (el mas rapido, ~15 FPS)
    seguridad   -> fuego + personas, animales, vehiculos y objetos (mochila, celular, cuchillo...)
    inspeccion  -> fuego + fisuras + oxido/corrosion (para revisar chasis, estructuras)
    todo        -> todo junto (el mas lento)
El fuego SIEMPRE esta activo.

La configuracion esta en config.json (camara, Telegram, modo inicial, alertas).
Servidor en la red (puerto 5000):
    /video     video MJPEG con recuadros          /estado   JSON con todo lo detectado
    /foto.jpg  ultimo cuadro                      /salud    {"ok": true}
    /modo      modo actual; /modo?m=inspeccion lo cambia
Se anuncia por UDP broadcast (puerto 5001) para que la app encuentre la PC sola.
Telegram: avisa la IP al arrancar, manda alertas con foto y responde /ip /foto /estado /modo.

Teclas en la ventana: 1 fuego, 2 seguridad, 3 inspeccion, 4 todo, q salir.

El video sale fluido (hasta VIDEO_FPS) aunque YOLO vaya lento: la IA corre en
su propio hilo sobre el cuadro mas nuevo y el video dibuja encima las
ultimas detecciones. /estado trae "fps" (de la IA), "video_fps" y "camara_ip".
"""
import argparse
import ipaddress
import json
import logging
import os
import socket
import threading
import time
from concurrent.futures import ThreadPoolExecutor

os.environ["OPENCV_FFMPEG_CAPTURE_OPTIONS"] = "rtsp_transport;tcp"  # RTSP mas estable

import cv2
import numpy as np
import psutil
import requests
from flask import Flask, Response, jsonify, request
from ultralytics import YOLO

CARPETA = os.path.dirname(os.path.abspath(__file__))
RUTA_CONFIG = os.path.join(CARPETA, "config.json")
CAPTURAS = os.path.join(CARPETA, "capturas")
PUERTO_ANUNCIO = 5001
VIDEO_FPS = 15  # tope del video MJPEG (la camara Tapo stream2 da ~15)

with open(RUTA_CONFIG, encoding="utf-8-sig") as f:  # -sig: acepta el archivo guardado con Bloc de notas
    config = json.load(f)
config.setdefault("modo", "seguridad")
config.setdefault("alertas", {})


def guardar_config():
    with open(RUTA_CONFIG, "w", encoding="utf-8") as f:
        json.dump(config, f, indent=2, ensure_ascii=False)


# ---------------- Modelos y modos ----------------

# Que dibujar y como llamarlo en español: clase original -> (etiqueta, categoria)
ETIQUETAS_OBJETOS = {
    "person": ("Persona", "persona"),
    "bicycle": ("Bicicleta", "vehiculo"), "car": ("Auto", "vehiculo"), "motorcycle": ("Moto", "vehiculo"),
    "bus": ("Autobus", "vehiculo"), "truck": ("Camion", "vehiculo"),
    "bird": ("Ave", "animal"), "cat": ("Gato", "animal"), "dog": ("Perro", "animal"), "horse": ("Caballo", "animal"),
    "sheep": ("Oveja", "animal"), "cow": ("Vaca", "animal"),
    "backpack": ("Mochila", "objeto"), "handbag": ("Bolso", "objeto"), "suitcase": ("Maleta", "objeto"),
    "knife": ("Cuchillo", "objeto"), "cell phone": ("Celular", "objeto"), "laptop": ("Laptop", "objeto"),
}
ETIQUETAS_OXIDO = {
    "mild-corrosion": "Oxido leve", "moderate-corrosion": "Oxido moderado", "severe-corrosion": "Oxido severo",
    "Rust": "Oxido", "rust": "Oxido", "iron rust": "Oxido", "corrosion": "Corrosion",
    "copper corrosion": "Corrosion", "corroded-part": "Pieza corroida",
}

# imgsz = tamaño al que YOLO mira el cuadro. Objetos/personas usan yolo11s
# (mas preciso que el nano) a 480: en esta laptop cuesta lo mismo que el nano
# a 640 y reconoce mejor a las personas (p. ej. 0.84 -> 0.94 en las pruebas).
MODELOS = {
    "fuego": {"archivo": "Fire_best.pt", "conf": 0.40, "imgsz": 640, "etiquetas": {"fire": ("FUEGO", "fuego")}},
    "objetos": {"archivo": "yolo11s.pt", "conf": 0.40, "imgsz": 480, "etiquetas": ETIQUETAS_OBJETOS},
    "fisuras": {"archivo": "fisuras_seg_n.pt", "conf": 0.50, "etiquetas": {"crack": ("Fisura", "fisura")}},
    "oxido": {"archivo": "corrosion_lite.pt", "conf": 0.25,
              "etiquetas": {k: (v, "oxido") for k, v in ETIQUETAS_OXIDO.items()}},
}
MODOS = {
    "fuego": ["fuego"],
    "seguridad": ["fuego", "objetos"],
    "inspeccion": ["fuego", "fisuras", "oxido"],
    "todo": ["fuego", "objetos", "fisuras", "oxido"],
}
TECLAS_MODO = {ord("1"): "fuego", ord("2"): "seguridad", ord("3"): "inspeccion", ord("4"): "todo"}


COLORES = {  # BGR
    "fuego": (0, 0, 255), "persona": (255, 140, 0), "vehiculo": (0, 200, 255), "animal": (60, 220, 60),
    "objeto": (255, 0, 255), "fisura": (255, 255, 0), "oxido": (30, 105, 210),
}
NOMBRES_PLURAL = {"persona": "Personas", "vehiculo": "Vehiculos", "animal": "Animales", "objeto": "Objetos",
                  "fisura": "Fisuras", "oxido": "Oxido", "fuego": "Fuego"}


def cargar_modelos():
    cargados = {}
    for nombre, info in MODELOS.items():
        m = YOLO(os.path.join(CARPETA, "modelos", info["archivo"]))
        # Solo pedirle al modelo las clases que nos interesan (mas rapido y sin ruido)
        ids = [i for i, n in m.names.items() if n in info["etiquetas"]]
        cargados[nombre] = (m, ids)
    return cargados


def iou(a, b):
    x1, y1, x2, y2 = max(a[0], b[0]), max(a[1], b[1]), min(a[2], b[2]), min(a[3], b[3])
    inter = max(0, x2 - x1) * max(0, y2 - y1)
    union = (a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - inter
    return inter / union if union else 0


def detectar(modelos, frame, modo):
    """Corre los modelos del modo y regresa una lista de detecciones en español."""
    dets = []
    for nombre in MODOS[modo]:
        m, ids = modelos[nombre]
        info = MODELOS[nombre]
        r = m.predict(frame, conf=info["conf"], classes=ids, imgsz=info.get("imgsz", 640), verbose=False)[0]
        poligonos = r.masks.xy if r.masks is not None else [None] * len(r.boxes)
        for c, s, xyxy, poli in zip(r.boxes.cls, r.boxes.conf, r.boxes.xyxy, poligonos):
            clase = m.names[int(c)]
            etiqueta, categoria = info["etiquetas"][clase]
            dets.append({"clase": clase, "etiqueta": etiqueta, "categoria": categoria,
                         "confianza": round(float(s), 2), "caja": [round(float(v)) for v in xyxy],
                         "_poligono": poli})
    # El modelo de oxido a veces confunde las llamas con corrosion: si coincide con un fuego, se descarta
    fuegos = [d["caja"] for d in dets if d["categoria"] == "fuego"]
    return [d for d in dets if d["categoria"] != "oxido" or all(iou(d["caja"], f) < 0.2 for f in fuegos)]


def dibujar(frame, dets):
    img = frame.copy()
    capa = img.copy()
    for d in dets:
        if d["_poligono"] is not None and len(d["_poligono"]) > 2:
            cv2.fillPoly(capa, [d["_poligono"].astype(np.int32)], COLORES[d["categoria"]])
    img = cv2.addWeighted(capa, 0.35, img, 0.65, 0)
    for d in dets:
        x1, y1, x2, y2 = d["caja"]
        color = COLORES[d["categoria"]]
        grosor = 3 if d["categoria"] == "fuego" else 2
        cv2.rectangle(img, (x1, y1), (x2, y2), color, grosor)
        texto = f"{d['etiqueta']} {d['confianza']:.0%}"
        (tw, th), _ = cv2.getTextSize(texto, cv2.FONT_HERSHEY_SIMPLEX, 0.6, 2)
        y_txt = max(y1, th + 8)
        cv2.rectangle(img, (x1, y_txt - th - 8), (x1 + tw + 6, y_txt), color, -1)
        cv2.putText(img, texto, (x1 + 3, y_txt - 5), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 0, 0), 2)
    return img


def contar(dets):
    conteo = {}
    for d in dets:
        conteo[d["categoria"]] = conteo.get(d["categoria"], 0) + 1
    return conteo


# ---------------- Red ----------------

def redes_locales():
    """IPs IPv4 de esta PC (Wi-Fi, hotspot, cable...) con su red."""
    activas = {n for n, s in psutil.net_if_stats().items() if s.isup}
    redes = []
    for nombre, direcciones in psutil.net_if_addrs().items():
        if nombre not in activas:
            continue
        for d in direcciones:
            if d.family != socket.AF_INET or not d.netmask:
                continue
            if d.address.startswith(("127.", "169.254.")):
                continue
            redes.append(ipaddress.IPv4Interface(f"{d.address}/{d.netmask}"))
    return redes


def urls_pc():
    return [f"http://{r.ip}:{config['puerto']}" for r in redes_locales()]


def puerto_abierto(ip, puerto=554, espera=0.7):
    try:
        with socket.create_connection((str(ip), puerto), timeout=espera):
            return True
    except OSError:
        return False


def url_rtsp(ip):
    return f"rtsp://{config['camara_usuario']}:{config['camara_contrasena']}@{ip}:554/{config['camara_stream']}"


def abrir_rtsp(url):
    return cv2.VideoCapture(url, cv2.CAP_FFMPEG,
                            [cv2.CAP_PROP_OPEN_TIMEOUT_MSEC, 10000, cv2.CAP_PROP_READ_TIMEOUT_MSEC, 10000])


def buscar_camara():
    """Prueba la ultima IP conocida; si no responde, busca en todas las redes de la PC."""
    ultima = config.get("camara_ip")
    if ultima and puerto_abierto(ultima, espera=2):
        return ultima
    candidatos = []
    for red in redes_locales():
        # En redes grandes (escuela) solo se revisa el /24 propio
        red = red.network if red.network.prefixlen >= 24 else ipaddress.ip_network(f"{red.ip}/24", strict=False)
        candidatos += [ip for ip in red.hosts() if ip not in candidatos]
    print(f"Buscando la camara en {len(candidatos)} direcciones...")
    with ThreadPoolExecutor(64) as ex:
        abiertos = [str(ip) for ip, ok in zip(candidatos, ex.map(puerto_abierto, candidatos)) if ok]
    for ip in abiertos:
        cap = abrir_rtsp(url_rtsp(ip))
        ok = cap.isOpened() and cap.read()[0]
        cap.release()
        if ok:
            print("Camara encontrada en", ip)
            config["camara_ip"] = ip
            guardar_config()
            return ip
    return None


class LectorUltimoFrame:
    """Lee la camara en un hilo aparte y guarda solo el frame mas reciente.
    Asi, aunque YOLO vaya lento, el video no se atrasa.
    Si la camara se desconecta o cambia de IP, la vuelve a buscar."""

    def __init__(self, fuente):
        self.fuente = fuente  # None = camara Tapo de config.json
        self.es_archivo = isinstance(fuente, str)
        self.ip = None  # IP de la Tapo abierta (solo con la camara de red)
        self.cap = None
        self.frame = None
        self.activo = True
        threading.Thread(target=self._leer, daemon=True).start()

    def _abrir(self):
        if self.fuente is not None:
            return cv2.VideoCapture(self.fuente)
        ip = buscar_camara()
        if ip is None:
            print("No encontre la camara. ¿Esta encendida y en la misma red que la PC?")
            return None
        self.ip = ip
        return abrir_rtsp(url_rtsp(ip))

    def _leer(self):
        while self.activo:
            ok, frame = self.cap.read() if self.cap is not None and self.cap.isOpened() else (False, None)
            if not ok:
                if self.es_archivo and self.cap is not None:
                    self.activo = False
                    break
                # /estado solo dice la IP de la camara mientras de verdad hay video
                # (la app la usa para corregir su URL RTSP).
                estado["camara_ip"] = None
                if self.cap is not None:
                    print("Sin video de la camara, reintentando...")
                    self.cap.release()
                    time.sleep(2)
                self.frame = None
                self.cap = self._abrir()
                if self.cap is None:
                    time.sleep(5)
                continue
            self.frame = frame
            estado["camara_ip"] = self.ip
            if self.es_archivo:
                time.sleep(1 / 30)

    def leer(self):
        return self.frame

    def cerrar(self):
        self.activo = False
        if self.cap is not None:
            self.cap.release()


def anunciar_en_red():
    """Cada 2 s grita en cada red "aqui esta el detector" para que la app lo encuentre sola."""
    while True:
        for red in redes_locales():
            msg = json.dumps({"servicio": "detector_fuego", "url": f"http://{red.ip}:{config['puerto']}"}).encode()
            try:
                with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
                    s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
                    s.bind((str(red.ip), 0))
                    s.sendto(msg, (str(red.network.broadcast_address), PUERTO_ANUNCIO))
            except OSError:
                pass
        time.sleep(2)


# ---------------- Estado compartido ----------------

ultimo_jpg = None
estado = {"camara": False, "modo": config["modo"], "fuego": False, "conteo": {}, "detecciones": [],
          "fps": 0.0, "video_fps": 0.0, "camara_ip": None, "ultimo_fuego": None,
          "actualizado": None}
nuevo_cuadro = threading.Condition()


def cambiar_modo(modo):
    if modo not in MODOS:
        return False
    config["modo"] = estado["modo"] = modo
    guardar_config()
    print("Modo:", modo)
    return True


# ---------------- Telegram ----------------

class Telegram:
    def __init__(self, token):
        self.api = f"https://api.telegram.org/bot{token}"
        threading.Thread(target=self._escuchar, daemon=True).start()

    def _texto_ip(self):
        urls = urls_pc()
        if not urls:
            return "La PC no esta conectada a ninguna red."
        lineas = ["🤖 Vision del robot encendida", "", "Pon esta direccion en la app:"]
        lineas += [f"{u}" for u in urls]
        lineas += ["", f"Camara: {config.get('camara_ip') or 'buscando...'}", f"Modo: {config['modo']}",
                   f"Video en el navegador: {urls[0]}/video"]
        return "\n".join(lineas)

    def enviar(self, texto, chat=None):
        for c in [chat] if chat else config["telegram_chats"]:
            try:
                requests.post(f"{self.api}/sendMessage", data={"chat_id": c, "text": texto}, timeout=10)
            except requests.RequestException:
                pass

    def enviar_foto(self, jpg, texto, chat=None):
        for c in [chat] if chat else config["telegram_chats"]:
            try:
                requests.post(f"{self.api}/sendPhoto", data={"chat_id": c, "caption": texto},
                              files={"photo": ("foto.jpg", jpg, "image/jpeg")}, timeout=20)
            except requests.RequestException:
                pass

    def _escuchar(self):
        # Espera a tener internet y avisa la IP a los chats ya registrados
        avisado = False
        desplazamiento = 0
        while True:
            try:
                r = requests.get(f"{self.api}/getUpdates",
                                 params={"offset": desplazamiento, "timeout": 30}, timeout=40).json()
            except (requests.RequestException, ValueError):
                time.sleep(5)
                continue
            if not avisado:
                self.enviar(self._texto_ip())
                avisado = True
            for u in r.get("result", []):
                desplazamiento = u["update_id"] + 1
                msg = u.get("message") or {}
                chat = msg.get("chat", {}).get("id")
                if chat is None:
                    continue
                if chat not in config["telegram_chats"]:
                    config["telegram_chats"].append(chat)
                    guardar_config()
                texto = (msg.get("text") or "").lower().strip()
                if texto.startswith("/foto"):
                    if ultimo_jpg is None:
                        self.enviar("Todavia no hay video de la camara.", chat)
                    else:
                        self.enviar_foto(ultimo_jpg, f"Vista actual (modo {config['modo']})", chat)
                elif texto.startswith("/estado"):
                    resumen = {k: v for k, v in estado.items() if k != "detecciones"}
                    self.enviar(json.dumps(resumen, indent=1, ensure_ascii=False), chat)
                elif texto.startswith("/modo"):
                    partes = texto.split()
                    if len(partes) > 1 and cambiar_modo(partes[1]):
                        self.enviar(f"✅ Modo cambiado a: {partes[1]}", chat)
                    else:
                        self.enviar(f"Modo actual: {config['modo']}\n\nCambia con:\n"
                                    "/modo fuego - solo fuego (rapido)\n"
                                    "/modo seguridad - fuego, personas, animales, vehiculos\n"
                                    "/modo inspeccion - fuego, fisuras, oxido\n"
                                    "/modo todo - todo (lento)", chat)
                else:  # /start, /ip o cualquier mensaje
                    self.enviar(self._texto_ip() + "\n\nComandos: /ip /foto /estado /modo", chat)


# ---------------- Servidor web ----------------

app = Flask(__name__)


@app.after_request
def permitir_cors(resp):
    resp.headers["Access-Control-Allow-Origin"] = "*"
    return resp


@app.route("/salud")
def salud():
    return jsonify(ok=True)


@app.route("/estado")
def ver_estado():
    return jsonify(estado)


@app.route("/modo")
def modo():
    nuevo = request.args.get("m")
    if nuevo is not None and not cambiar_modo(nuevo):
        return jsonify(error=f"modo desconocido: {nuevo}", modos=list(MODOS)), 400
    return jsonify(modo=config["modo"], modos=list(MODOS))


@app.route("/foto.jpg")
def foto():
    if ultimo_jpg is None:
        return "Sin video todavia", 503
    return Response(ultimo_jpg, mimetype="image/jpeg")


@app.route("/video")
def video():
    def generar():
        while True:
            with nuevo_cuadro:
                nuevo_cuadro.wait(timeout=2)
            if ultimo_jpg is None:
                continue
            yield (b"--frame\r\nContent-Type: image/jpeg\r\nContent-Length: "
                   + str(len(ultimo_jpg)).encode() + b"\r\n\r\n" + ultimo_jpg + b"\r\n")

    return Response(generar(), mimetype="multipart/x-mixed-replace; boundary=frame")


# ---------------- Programa principal ----------------

class Estabilizador:
    """Menos falsas alarmas y menos parpadeo en personas, vehiculos, animales,
    objetos, fisuras y oxido (el FUEGO nunca se filtra: siempre inmediato).
    - Una deteccion debil (< FUERTE) solo cuenta si se repite en el analisis
      siguiente en el mismo lugar (IoU >= 0.3, misma categoria).
    - Una deteccion ya confirmada que falta UN analisis se conserva (su
      recuadro no parpadea)."""

    FUERTE = 0.60

    def __init__(self):
        self.previas = []  # detecciones del analisis anterior (crudas)
        self.confirmadas = []  # lo que se mostro la vez anterior

    @staticmethod
    def _igual(a, b):
        return a["categoria"] == b["categoria"] and iou(a["caja"], b["caja"]) >= 0.3

    def filtrar(self, dets):
        salida = []
        for d in dets:
            if (d["categoria"] == "fuego" or d["confianza"] >= self.FUERTE
                    or any(self._igual(d, p) for p in self.previas + self.confirmadas)):
                salida.append(d)
        # Confirmadas (no fuego) que hoy faltaron: se mantienen un analisis mas.
        for c in self.confirmadas:
            if c["categoria"] != "fuego" and not c.get("_retenida") and not any(self._igual(c, d) for d in dets):
                salida.append({**c, "_retenida": True})
        self.previas = dets
        self.confirmadas = salida
        return salida


class HiloIA:
    """Corre YOLO en su propio hilo sobre el cuadro MAS NUEVO de la camara.
    Asi el video no espera a la IA: se manda fluido con las ultimas
    detecciones encima (en esta PC sin GPU la IA va a 2-8 FPS segun el modo)."""

    def __init__(self, modelos, lector):
        self.modelos, self.lector = modelos, lector
        self.activo = True
        self._dets, self._fps, self._modo, self._n = [], 0.0, config["modo"], 0
        self._lock = threading.Lock()
        self.estabilizador = Estabilizador()
        threading.Thread(target=self._correr, daemon=True).start()

    def _correr(self):
        ultimo = None
        while self.activo:
            frame = self.lector.leer()
            if frame is None or frame is ultimo:
                time.sleep(0.01)
                continue
            ultimo = frame
            modo = config["modo"]
            t0 = time.time()
            try:
                dets = self.estabilizador.filtrar(detectar(self.modelos, frame, modo))
            except Exception as e:  # un cuadro raro no debe tumbar la IA
                print("Error de la IA:", e)
                time.sleep(0.5)
                continue
            with self._lock:
                self._dets, self._fps, self._modo = dets, 1 / max(time.time() - t0, 1e-3), modo
                self._n += 1

    def resultado(self):
        """(detecciones, fps de la IA, modo con el que se detecto, numero de resultado)."""
        with self._lock:
            # Si cambiaron de modo, no se dibujan detecciones del modo anterior.
            if self._modo != config["modo"]:
                return [], self._fps, config["modo"], self._n
            return self._dets, self._fps, self._modo, self._n


def texto_borde(img, texto, pos, escala, color, grosor=2):
    cv2.putText(img, texto, pos, cv2.FONT_HERSHEY_SIMPLEX, escala, (0, 0, 0), grosor + 3)
    cv2.putText(img, texto, pos, cv2.FONT_HERSHEY_SIMPLEX, escala, color, grosor)


def main():
    global ultimo_jpg
    ap = argparse.ArgumentParser()
    ap.add_argument("--fuente", default=None, help="indice de webcam (0) o archivo; vacio = camara Tapo")
    ap.add_argument("--modo", choices=list(MODOS), help="modo inicial (si no, el de config.json)")
    ap.add_argument("--sin-ventana", action="store_true", help="no abrir ventana en la PC")
    args = ap.parse_args()
    if args.modo:
        cambiar_modo(args.modo)
    if config["modo"] not in MODOS:
        cambiar_modo("seguridad")

    fuente = args.fuente
    if fuente is not None and fuente.isdigit():
        fuente = int(fuente)
    print("Cargando modelos...")
    modelos = cargar_modelos()
    os.makedirs(CAPTURAS, exist_ok=True)

    logging.getLogger("werkzeug").setLevel(logging.ERROR)
    threading.Thread(target=lambda: app.run(host="0.0.0.0", port=config["puerto"], threaded=True),
                     daemon=True).start()
    threading.Thread(target=anunciar_en_red, daemon=True).start()
    bot = Telegram(config["telegram_token"]) if config.get("telegram_token") else None

    print("\n=== Pon esta direccion en la app ===")
    for u in urls_pc():
        print("   ", u)
    print("====================================")
    print("Teclas: 1 fuego | 2 seguridad | 3 inspeccion | 4 todo | q salir\n")

    lector = LectorUltimoFrame(fuente)
    ia = HiloIA(modelos, lector)
    ultima_captura = {}
    ultima_alerta = {}
    texto_ip, texto_ip_t = "", 0
    ultimo_frame, ultimo_resultado = None, -1
    t_video, cuadros_video, t_cuenta = 0.0, 0, time.time()
    while lector.activo or lector.leer() is not None:
        frame = lector.leer()
        tecla = -1
        if frame is None:
            estado["camara"] = False
            if not args.sin_ventana:
                espera = np.zeros((360, 900, 3), np.uint8)
                cv2.putText(espera, "Buscando la camara...", (40, 160), cv2.FONT_HERSHEY_SIMPLEX, 1.4,
                            (255, 255, 255), 3)
                cv2.putText(espera, "App: " + "  |  ".join(urls_pc()), (40, 240),
                            cv2.FONT_HERSHEY_SIMPLEX, 0.75, (0, 255, 255), 2)
                cv2.imshow("Vision del robot", espera)
                tecla = cv2.waitKey(200) & 0xFF
            else:
                time.sleep(0.05)
            if tecla == ord("q"):
                break
            continue
        estado["camara"] = True

        # Solo cuadros nuevos de la camara y como mucho VIDEO_FPS por segundo.
        ahora = time.time()
        if frame is ultimo_frame or ahora - t_video < 1 / VIDEO_FPS:
            if not args.sin_ventana:
                tecla = cv2.waitKey(5) & 0xFF
                if tecla == ord("q"):
                    break
                if tecla in TECLAS_MODO:
                    cambiar_modo(TECLAS_MODO[tecla])
            else:
                time.sleep(0.005)
            continue
        ultimo_frame, t_video = frame, ahora
        cuadros_video += 1
        if ahora - t_cuenta >= 2:
            estado["video_fps"] = round(cuadros_video / (ahora - t_cuenta), 1)
            cuadros_video, t_cuenta = 0, ahora

        dets, fps, modo, n_resultado = ia.resultado()
        anotado = dibujar(frame, dets)
        conteo = contar(dets)
        hay_fuego = "fuego" in conteo

        alto, ancho = anotado.shape[:2]
        if hay_fuego:
            texto_borde(anotado, "!!! FUEGO DETECTADO !!!", (20, 80), 1.2, (0, 0, 255), 3)
        # Conteo arriba a la derecha
        y = 30
        for cat, n in conteo.items():
            if cat == "fuego":
                continue
            texto_borde(anotado, f"{NOMBRES_PLURAL[cat]}: {n}", (ancho - 230, y), 0.7, COLORES[cat])
            y += 28
        pie = f"{modo.upper()} | IA {fps:.1f} FPS"
        (tw, _), _ = cv2.getTextSize(pie, cv2.FONT_HERSHEY_SIMPLEX, 0.65, 2)
        texto_borde(anotado, pie, (ancho - tw - 15, alto - 20), 0.65, (0, 255, 0))

        ultimo_jpg = cv2.imencode(".jpg", anotado, [cv2.IMWRITE_JPEG_QUALITY, 80])[1].tobytes()
        with nuevo_cuadro:
            nuevo_cuadro.notify_all()

        # Estado, capturas y alertas: solo cuando la IA entrega un resultado nuevo
        # (mismos tiempos de espera que antes, por tipo).
        if n_resultado != ultimo_resultado:
            ultimo_resultado = n_resultado
            if hay_fuego:
                estado["ultimo_fuego"] = time.strftime("%Y-%m-%dT%H:%M:%S")
            estado.update(modo=modo, fuego=hay_fuego, conteo=conteo, fps=round(fps, 1),
                          detecciones=[{k: v for k, v in d.items() if not k.startswith("_")} for d in dets],
                          actualizado=time.strftime("%Y-%m-%dT%H:%M:%S"))
            for ev in conteo:
                cada = 3 if ev == "fuego" else 30
                if ev in ("fuego", "fisura", "oxido", "persona") and ahora - ultima_captura.get(ev, 0) > cada:
                    cv2.imwrite(os.path.join(CAPTURAS, f"{ev}_{time.strftime('%Y%m%d_%H%M%S')}.jpg"), anotado)
                    ultima_captura[ev] = ahora
                    if ev == "fuego":
                        print(time.strftime("%H:%M:%S"), "FUEGO DETECTADO")
                espera = 30 if ev == "fuego" else 60
                if bot and config["alertas"].get(ev) and ahora - ultima_alerta.get(ev, 0) > espera:
                    if ev == "fuego":
                        conf_max = max(d["confianza"] for d in dets if d["categoria"] == "fuego")
                        texto = f"🔥 ¡FUEGO DETECTADO! (confianza {conf_max:.0%})"
                    else:
                        texto = f"👁 {NOMBRES_PLURAL[ev]} detectado(s): {conteo[ev]} (modo {modo})"
                    threading.Thread(target=bot.enviar_foto, args=(ultimo_jpg, texto), daemon=True).start()
                    ultima_alerta[ev] = ahora

        if not args.sin_ventana:
            # La IP y las teclas solo se dibujan en la ventana de la PC, no en el video de la app
            if time.time() - texto_ip_t > 5:
                texto_ip, texto_ip_t = "App: " + "  |  ".join(urls_pc()), time.time()
            local = anotado.copy()
            cv2.rectangle(local, (0, alto - 50), (ancho - tw - 30, alto), (0, 0, 0), -1)
            cv2.putText(local, texto_ip, (10, alto - 28), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 255, 255), 2)
            cv2.putText(local, "1 fuego  2 seguridad  3 inspeccion  4 todo  q salir", (10, alto - 8),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.5, (200, 200, 200), 1)
            cv2.imshow("Vision del robot", local)
            tecla = cv2.waitKey(1) & 0xFF
            if tecla == ord("q"):
                break
            if tecla in TECLAS_MODO:
                cambiar_modo(TECLAS_MODO[tecla])

    ia.activo = False
    lector.cerrar()
    cv2.destroyAllWindows()


if __name__ == "__main__":
    main()
