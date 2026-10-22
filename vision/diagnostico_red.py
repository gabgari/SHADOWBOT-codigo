"""Diagnostico de red de SHADOW BOT (para el dia de la exposicion).

Busca en la red donde esta la laptop (Wi-Fi o hotspot del celular) todos los
equipos del proyecto y dice su IP:
    CONTROL (ESP32-S3)    puerto 80, /estado con "modo"
    SENSORES (ESP8266)    puerto 80, /sensors con "mq2"
    CAM 1 (ESP32-S3 CAM)  puerto 80, /estado con "cam" (video en :81/stream)
    CAM 2 (Tapo C110)     puerto 554, comprueba usuario/clave de config.json
    Detector YOLO         puerto 5000, /salud

Solo lee: no mueve motores, no cambia modos, no manda nada a Telegram.
Uso:   .venv\\Scripts\\python.exe diagnostico_red.py
       (o doble clic en diagnostico_red.bat)
"""
import hashlib
import ipaddress
import json
import os
import re
import socket
import urllib.request
from concurrent.futures import ThreadPoolExecutor

CARPETA = os.path.dirname(os.path.abspath(__file__))
with open(os.path.join(CARPETA, "config.json"), encoding="utf-8-sig") as f:
    CONFIG = json.load(f)


def redes_locales():
    """IPs IPv4 de esta PC con su red /24 (sin loopback ni 169.254)."""
    ips = set()
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            ips.add(info[4][0])
    except OSError:
        pass
    try:  # la IP de salida real (la del Wi-Fi activo)
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect(("8.8.8.8", 80))
            ips.add(s.getsockname()[0])
    except OSError:
        pass
    return sorted(ip for ip in ips if not ip.startswith(("127.", "169.254.")))


def abierto(ip, puerto, espera=0.6):
    try:
        with socket.create_connection((ip, puerto), timeout=espera):
            return True
    except OSError:
        return False


def get_json(url, espera=2.5):
    try:
        with urllib.request.urlopen(url, timeout=espera) as r:
            return json.loads(r.read().decode("utf-8", "replace"))
    except Exception:
        return None


def rtsp_clave_ok(ip, usuario, clave, stream, puerto=554):
    """DESCRIBE con Digest/Basic: True acepta, False rechaza, None no responde."""
    uri = f"rtsp://{ip}:{puerto}/{stream}"

    def pedir(cseq, auth=None):
        try:
            with socket.create_connection((ip, puerto), timeout=4) as s:
                msg = f"DESCRIBE {uri} RTSP/1.0\r\nCSeq: {cseq}\r\nAccept: application/sdp\r\n"
                if auth:
                    msg += f"Authorization: {auth}\r\n"
                s.sendall((msg + "\r\n").encode())
                s.settimeout(4)
                datos = b""
                while b"\r\n\r\n" not in datos:
                    parte = s.recv(2048)
                    if not parte:
                        break
                    datos += parte
                return datos.decode("latin-1")
        except OSError:
            return None

    r1 = pedir(1)
    m = re.match(r"RTSP/1\.\d (\d{3})", r1 or "")
    if not m:
        return None
    if m.group(1) == "200":
        return True
    if m.group(1) != "401":
        return False
    linea = next((l for l in r1.split("\r\n") if l.lower().startswith("www-authenticate:")), "")
    if "digest" in linea.lower():
        realm = (re.search(r'realm="([^"]*)"', linea) or [None, ""])[1]
        nonce = (re.search(r'nonce="([^"]*)"', linea) or [None, ""])[1]
        md5 = lambda t: hashlib.md5(t.encode()).hexdigest()
        resp = md5(f"{md5(f'{usuario}:{realm}:{clave}')}:{nonce}:{md5(f'DESCRIBE:{uri}')}")
        auth = f'Digest username="{usuario}", realm="{realm}", nonce="{nonce}", uri="{uri}", response="{resp}"'
    else:
        import base64
        auth = "Basic " + base64.b64encode(f"{usuario}:{clave}".encode()).decode()
    r2 = pedir(2, auth)
    m2 = re.match(r"RTSP/1\.\d (\d{3})", r2 or "")
    return None if not m2 else m2.group(1) == "200"


def revisar(ip):
    """Que equipo es esta IP (o None)."""
    hallados = []
    if abierto(ip, 80):
        est = get_json(f"http://{ip}/estado")
        if isinstance(est, dict) and "modo" in est:
            hallados.append(("CONTROL", f"modo {est.get('modo')} | LCD {'si' if est.get('lcdok') else 'no'}"))
        elif isinstance(est, dict) and "cam" in est:
            hallados.append(("CAM 1 (ESP32-CAM)", "camara OK" if est.get("cam") else f"camara NO inicio (error {est.get('err')})"))
        else:
            sen = get_json(f"http://{ip}/sensors")
            if isinstance(sen, dict) and "mq2" in sen:
                hallados.append(("SENSORES", f"MQ-2 = {sen.get('mq2')}"))
    if abierto(ip, 554):
        ok = rtsp_clave_ok(ip, CONFIG["camara_usuario"], CONFIG["camara_contrasena"], CONFIG["camara_stream"])
        detalle = {True: "ACEPTA usuario/clave (es la del carrito)", False: "rechaza la clave (otra camara)", None: "no responde RTSP"}[ok]
        hallados.append(("CAM 2 (Tapo RTSP)" if ok else "camara RTSP ajena", detalle))
    if abierto(ip, 5000):
        if (get_json(f"http://{ip}:5000/salud") or {}).get("ok"):
            e = get_json(f"http://{ip}:5000/estado") or {}
            hallados.append(("Detector YOLO", f"camara {'SI' if e.get('camara') else 'NO'} | modo {e.get('modo')} | IA {e.get('fps')} fps"))
    return [(ip, n, d) for n, d in hallados]


def main():
    propias = redes_locales()
    if not propias:
        print("La laptop no esta conectada a ninguna red.")
        return
    print("IPs de esta laptop:", ", ".join(propias))
    hosts = []
    for ip in propias:
        red = ipaddress.ip_network(f"{ip}/24", strict=False)
        hosts += [str(h) for h in red.hosts() if str(h) not in hosts]
    print(f"Revisando {len(hosts)} direcciones (unos 20-40 s)...\n")
    with ThreadPoolExecutor(64) as ex:
        resultados = [r for lista in ex.map(revisar, hosts) for r in lista]

    orden = ["CONTROL", "SENSORES", "CAM 1 (ESP32-CAM)", "CAM 2 (Tapo RTSP)", "Detector YOLO", "camara RTSP ajena"]
    resultados.sort(key=lambda r: (orden.index(r[1]) if r[1] in orden else 99, r[0]))
    for ip, nombre, detalle in resultados:
        print(f"  {nombre:20s} {ip:16s} {detalle}")
    encontrados = {r[1] for r in resultados}
    faltan = [n for n in orden[:5] if n not in encontrados]
    if faltan:
        print("\nNO encontrados:", ", ".join(faltan))

    tapo = next((r[0] for r in resultados if r[1] == "CAM 2 (Tapo RTSP)"), None)
    cam1 = next((r[0] for r in resultados if r[1] == "CAM 1 (ESP32-CAM)"), None)
    print("\nPara la app (Sistema > Conexiones):")
    if cam1:
        print(f"  ESP32-CAM:  {cam1}")
    if tapo:
        print(f"  Tapo RTSP:  rtsp://{CONFIG['camara_usuario']}:{CONFIG['camara_contrasena']}@{tapo}:554/{CONFIG['camara_stream']}")
    print("  (CONTROL, SENSORES y la PC de vision la app los encuentra sola)")


if __name__ == "__main__":
    main()
