# SHADOW BOT

Vehículo teleoperado de inspección con visión artificial. Proyecto integrador de Ingeniería en Telecomunicaciones (UAEH, 2026).

- Página del proyecto: https://gabgari.github.io/SHADOW-BOT/
- Documentación técnica (formato IEEE): [docs/shadowbot-ieee.pdf](docs/shadowbot-ieee.pdf)

## Arquitectura

```
                         Wi-Fi (misma red)
 ┌──────────────┐   MJPEG   ┌──────────────────────────────┐
 │ ESP32-S3 CAM │ ────────► │                              │
 └──────────────┘           │   Tablet Android (Flutter)   │ ◄── DualShock 4 (Bluetooth)
 ┌──────────────┐  HTTP/UDP │   consola del operador       │
 │ ESP32-S3     │ ◄───────► │                              │
 │ CONTROL      │           └──────────────────────────────┘
 │ motores, LCD │                 ▲ MJPEG anotado (HTTP :5000)
 └──────────────┘                 │
 ┌──────────────┐           ┌─────┴──────────────┐  RTSP  ┌──────────────┐
 │ ESP8266      │           │ PC: servidor YOLO  │ ◄───── │ Tapo C110    │
 │ MQ-2 + LEDs  │           │ (Python, OpenCV)   │        │ cámara IP    │
 └──────────────┘           └────────────────────┘        └──────────────┘
```

- **Tres placas** que se anuncian por UDP y la app las encuentra sola.
- **Servidor de visión:** recibe el video RTSP de la Tapo, corre YOLO (fuego, personas, vehículos, objetos; fisuras y óxido en modo inspección) y devuelve el video anotado como MJPEG a ~12 fps. Envía alertas con foto por Telegram.
- **Seguridad del vehículo:** si el control deja de recibir órdenes durante 800 ms, detiene los motores.
- **App:** video de ambas cámaras, manejo con mando, lectura del sensor de gas, grabación y descripción de escena con la API de Gemini.

## Estructura

| Carpeta | Contenido |
|---|---|
| `firmware/` | Código Arduino de las tres placas: `CAMARA` (ESP32-S3), `CONTROL` (ESP32-S3: puentes BTS7960, servos del brazo, LCD 16x2 I2C) y `SENSORES_8266` (MQ-2 y LEDs). |
| `vision/` | Servidor de detección en Python (Ultralytics YOLO, OpenCV, Flask) y scripts de instalación para Windows. |
| `app/` | App Flutter para la tablet. |
| `docs/` | Documento IEEE, diagrama de conexiones, manuales y comandos del mando. |

## Cómo usarlo

1. **Firmware:** en cada `.ino` cambia `TU_RED_WIFI` / `TU_CONTRASENA_WIFI` (y en `CAMARA.ino` el token y chat de Telegram si usarás alertas). Compila con Arduino IDE o `arduino-cli`.
2. **Visión:** copia `vision/config.example.json` como `config.json`, pon los modelos en `vision/modelos/` y sigue `vision/LEEME.txt`.
3. **App:** `cd app && flutter pub get && flutter run`. La clave de Gemini se escribe en Ajustes dentro de la app.

Ninguna contraseña, token ni modelo de terceros está incluido en el repositorio.

## Autor

Ángel Gabriel García Rivera · [gabgari.github.io](https://gabgari.github.io/)
