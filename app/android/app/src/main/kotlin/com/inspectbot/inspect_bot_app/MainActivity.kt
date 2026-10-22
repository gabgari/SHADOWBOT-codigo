package com.inspectbot.inspect_bot_app

import android.content.Context
import android.graphics.Color
import android.hardware.input.InputManager
import android.hardware.lights.LightState
import android.hardware.lights.LightsManager
import android.hardware.lights.LightsRequest
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.VibrationEffect
import android.view.InputDevice
import android.view.KeyEvent
import android.view.MotionEvent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * Mando de PS4 (o cualquier gamepad) conectado AL TELÉFONO por Bluetooth/USB.
 *
 * Lee sticks, gatillos, cruceta y botones directo de Android y se los pasa a
 * Flutter por "shadowbot/gamepad/events" (ver lib/state/gamepad_link.dart).
 * Por "shadowbot/gamepad" Flutter puede pedir el mando conectado, poner el
 * color de la barra de luz (Android 12+) y hacerlo vibrar.
 *
 * Solo se consumen eventos que vienen de un gamepad/joystick: el teclado,
 * la pantalla táctil y el botón atrás del teléfono siguen igual.
 */
class MainActivity : FlutterActivity() {
    private var events: EventChannel.EventSink? = null
    private val main = Handler(Looper.getMainLooper())
    private var lightsSession: LightsManager.LightsSession? = null
    private var lightsDeviceId = -1

    private val deviceListener = object : InputManager.InputDeviceListener {
        override fun onInputDeviceAdded(deviceId: Int) = reportConnection()
        override fun onInputDeviceRemoved(deviceId: Int) = reportConnection()
        override fun onInputDeviceChanged(deviceId: Int) = reportConnection()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        EventChannel(messenger, "shadowbot/gamepad/events").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
                events = sink
                reportConnection()
            }
            override fun onCancel(arguments: Any?) { events = null }
        })

        // Descubrimiento de la PC de visión (anuncio UDP broadcast, puerto
        // 5001): muchos teléfonos tiran los broadcast si nadie tiene un
        // MulticastLock. Flutter lo pide mientras escucha y lo suelta al cerrar.
        MethodChannel(messenger, "shadowbot/net").setMethodCallHandler { call, result ->
            when (call.method) {
                "multicastLock" -> result.success(setMulticastLock(true))
                "multicastUnlock" -> result.success(setMulticastLock(false))
                else -> result.notImplemented()
            }
        }

        MethodChannel(messenger, "shadowbot/gamepad").setMethodCallHandler { call, result ->
            when (call.method) {
                "status" -> result.success(gamepadInfo())
                "light" -> {
                    val r = call.argument<Int>("r") ?: 0
                    val g = call.argument<Int>("g") ?: 0
                    val b = call.argument<Int>("b") ?: 0
                    result.success(setLight(r, g, b))
                }
                // Barra de luz: "fire" = fuego animado del color r,g,b (rojo si no
                // se manda), "duo" = fuego que alterna r,g,b y r2,g2,b2 (SPORT:
                // azul y rojo), "solid" = color fijo, "off".
                "lightMode" -> {
                    lightMode = call.argument<String>("mode") ?: "fire"
                    val hasColor = call.hasArgument("r")
                    solidColor = Color.rgb(call.argument<Int>("r") ?: 0, call.argument<Int>("g") ?: 200, call.argument<Int>("b") ?: 40)
                    fireColor = if (hasColor) solidColor else FIRE_RED
                    fireColor2 = Color.rgb(call.argument<Int>("r2") ?: 0, call.argument<Int>("g2") ?: 60, call.argument<Int>("b2") ?: 255)
                    firePeriod = (call.argument<Int>("period") ?: 70).toLong().coerceIn(30, 400)
                    fireHeat = ((call.argument<Int>("heat") ?: 60) / 100f).coerceIn(0.1f, 1f)
                    restartLight()
                    result.success(Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && hasRgbLight())
                }
                // Destello corto de un color (aviso), y vuelve al modo de luz anterior.
                "flash" -> {
                    val c = Color.rgb(call.argument<Int>("r") ?: 255, call.argument<Int>("g") ?: 255, call.argument<Int>("b") ?: 255)
                    flashUntil = System.currentTimeMillis() + (call.argument<Int>("ms") ?: 250)
                    flashColor = c
                    restartLight()
                    result.success(true)
                }
                "rumble" -> {
                    val ms = (call.argument<Int>("ms") ?: 150).toLong()
                    val amp = call.argument<Int>("amp") ?: 200
                    result.success(rumble(ms, amp))
                }
                else -> result.notImplemented()
            }
        }

        (getSystemService(Context.INPUT_SERVICE) as InputManager).registerInputDeviceListener(deviceListener, main)
    }

    private var multicastLock: WifiManager.MulticastLock? = null

    private fun setMulticastLock(on: Boolean): Boolean {
        return try {
            if (on) {
                val lock = multicastLock ?: (applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager)
                    .createMulticastLock("shadowbot-vision").also {
                        it.setReferenceCounted(false)
                        multicastLock = it
                    }
                if (!lock.isHeld) lock.acquire()
            } else {
                multicastLock?.let { if (it.isHeld) it.release() }
            }
            true
        } catch (e: Exception) {
            false
        }
    }

    override fun onDestroy() {
        setMulticastLock(false)
        main.removeCallbacks(lightTick)
        (getSystemService(Context.INPUT_SERVICE) as InputManager).unregisterInputDeviceListener(deviceListener)
        closeLights()
        super.onDestroy()
    }

    // ---------------- Detección del mando ----------------

    private fun isGamepad(device: InputDevice?): Boolean {
        if (device == null || device.isVirtual) return false
        val s = device.sources
        if ((s and InputDevice.SOURCE_GAMEPAD) == InputDevice.SOURCE_GAMEPAD ||
            (s and InputDevice.SOURCE_JOYSTICK) == InputDevice.SOURCE_JOYSTICK) return true
        // Algunos mandos (clones de DS4, o ya vinculados en otro modo) se
        // anuncian solo como teclado/D-pad: si tienen botones de gamepad
        // (✕ ○) y no son del propio teléfono, también cuentan como mando.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && !device.isExternal) return false
        return try {
            device.hasKeys(KeyEvent.KEYCODE_BUTTON_A, KeyEvent.KEYCODE_BUTTON_B).all { it }
        } catch (_: Exception) { false }
    }

    // Primero el que tenga sticks (el DS4 crea además "Touchpad" y "Motion
    // Sensors" como dispositivos aparte); si no, cualquiera con botones.
    private fun firstGamepad(): InputDevice? {
        val pads = ArrayList<InputDevice>()
        for (id in InputDevice.getDeviceIds()) {
            val d = InputDevice.getDevice(id)
            if (d != null && isGamepad(d)) pads.add(d)
        }
        return pads.firstOrNull { d -> (d.sources and InputDevice.SOURCE_JOYSTICK) == InputDevice.SOURCE_JOYSTICK } ?: pads.firstOrNull()
    }

    private fun gamepadInfo(): Map<String, Any?> {
        val d = firstGamepad()
        return mapOf("t" to "conn", "connected" to (d != null), "name" to d?.name, "id" to (d?.id ?: -1))
    }

    private fun reportConnection() {
        val info = gamepadInfo()
        if ((info["id"] as Int) != lightsDeviceId) closeLights()
        if (info["connected"] == true && lightMode != "off") restartLight()
        main.post { events?.success(info) }
    }

    // ---------------- Botones y cruceta ----------------

    private fun keyName(code: Int): String? = when (code) {
        KeyEvent.KEYCODE_BUTTON_A -> "A"            // ✕
        KeyEvent.KEYCODE_BUTTON_B -> "B"            // ○
        KeyEvent.KEYCODE_BUTTON_X -> "X"            // □
        KeyEvent.KEYCODE_BUTTON_Y -> "Y"            // △
        KeyEvent.KEYCODE_BUTTON_L1 -> "L1"
        KeyEvent.KEYCODE_BUTTON_R1 -> "R1"
        KeyEvent.KEYCODE_BUTTON_L2 -> "L2"
        KeyEvent.KEYCODE_BUTTON_R2 -> "R2"
        KeyEvent.KEYCODE_BUTTON_THUMBL -> "L3"
        KeyEvent.KEYCODE_BUTTON_THUMBR -> "R3"
        KeyEvent.KEYCODE_BUTTON_START -> "OPTIONS"
        KeyEvent.KEYCODE_BUTTON_SELECT -> "SHARE"
        KeyEvent.KEYCODE_BUTTON_MODE -> "PS"
        KeyEvent.KEYCODE_DPAD_UP -> "UP"
        KeyEvent.KEYCODE_DPAD_DOWN -> "DOWN"
        KeyEvent.KEYCODE_DPAD_LEFT -> "LEFT"
        KeyEvent.KEYCODE_DPAD_RIGHT -> "RIGHT"
        else -> null
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (isGamepad(event.device) || (KeyEvent.isGamepadButton(event.keyCode) && event.device?.isVirtual == false)) {
            val name = keyName(event.keyCode)
            if (name != null) {
                if (event.repeatCount == 0 && (event.action == KeyEvent.ACTION_DOWN || event.action == KeyEvent.ACTION_UP)) {
                    events?.success(mapOf("t" to "btn", "k" to name, "down" to (event.action == KeyEvent.ACTION_DOWN)))
                }
                return true   // no llega a Flutter ni dispara "atrás" con ○
            }
        }
        return super.dispatchKeyEvent(event)
    }

    // ---------------- Sticks y gatillos ----------------

    private fun axis(e: MotionEvent, a: Int): Float = e.getAxisValue(a)

    private fun trigger(e: MotionEvent, d: InputDevice, primary: Int, alt: Int, legacy: Int): Float {
        if (d.getMotionRange(primary, e.source) != null) return axis(e, primary)
        if (d.getMotionRange(alt, e.source) != null) return axis(e, alt)
        // Androids viejos reportan L2/R2 del DS4 en RX/RY con rango -1..1.
        if (d.getMotionRange(legacy, e.source) != null) return (axis(e, legacy) + 1f) / 2f
        return 0f
    }

    override fun dispatchGenericMotionEvent(event: MotionEvent): Boolean {
        val d = event.device
        if (isGamepad(d) && (event.source and InputDevice.SOURCE_JOYSTICK) == InputDevice.SOURCE_JOYSTICK &&
            event.action == MotionEvent.ACTION_MOVE) {
            val rxAxis = if (d.getMotionRange(MotionEvent.AXIS_Z, event.source) != null) MotionEvent.AXIS_Z else MotionEvent.AXIS_RX
            val ryAxis = if (d.getMotionRange(MotionEvent.AXIS_RZ, event.source) != null) MotionEvent.AXIS_RZ else MotionEvent.AXIS_RY
            events?.success(
                mapOf(
                    "t" to "axes",
                    "lx" to axis(event, MotionEvent.AXIS_X).toDouble(),
                    "ly" to axis(event, MotionEvent.AXIS_Y).toDouble(),
                    "rx" to axis(event, rxAxis).toDouble(),
                    "ry" to axis(event, ryAxis).toDouble(),
                    "lt" to trigger(event, d, MotionEvent.AXIS_LTRIGGER, MotionEvent.AXIS_BRAKE, MotionEvent.AXIS_RX).toDouble(),
                    "rt" to trigger(event, d, MotionEvent.AXIS_RTRIGGER, MotionEvent.AXIS_GAS, MotionEvent.AXIS_RY).toDouble(),
                    "hx" to axis(event, MotionEvent.AXIS_HAT_X).toDouble(),
                    "hy" to axis(event, MotionEvent.AXIS_HAT_Y).toDouble(),
                )
            )
            return true
        }
        return super.dispatchGenericMotionEvent(event)
    }

    // ---------------- Barra de luz y vibración ----------------

    private fun setLight(r: Int, g: Int, b: Int): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return false
        return try {
            val d = firstGamepad() ?: return false
            val lm = d.lightsManager
            val rgb = lm.lights.firstOrNull { it.hasRgbControl() } ?: return false
            if (lightsSession == null || lightsDeviceId != d.id) {
                closeLights()
                lightsSession = lm.openSession()
                lightsDeviceId = d.id
            }
            val state = LightState.Builder().setColor(Color.rgb(r, g, b)).build()
            lightsSession?.requestLights(LightsRequest.Builder().addLight(rgb, state).build())
            true
        } catch (e: Exception) {
            false
        }
    }

    // ---------------- Fuego (de cualquier color) en la barra de luz ----------------
    private val FIRE_RED = Color.rgb(255, 0, 0)
    private var fireColor = FIRE_RED
    private var fireColor2 = Color.rgb(0, 60, 255)
    private val hsv = FloatArray(3)
    private var lightMode = "off"
    private var solidColor = Color.rgb(0, 200, 40)
    private var firePeriod = 70L
    private var fireHeat = 0.6f
    private var fireLevel = 0.5f
    private var flashUntil = 0L
    private var flashColor = Color.WHITE
    private val rnd = java.util.Random()

    private fun hasRgbLight(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return false
        return try { firstGamepad()?.lightsManager?.lights?.any { it.hasRgbControl() } == true } catch (_: Exception) { false }
    }

    private val lightTick = object : Runnable {
        override fun run() {
            if (firstGamepad() == null || Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return   // sin mando o sin API de luces: no hace nada
            val now = System.currentTimeMillis()
            if (now < flashUntil) {
                setLightColor(flashColor)
                main.postDelayed(this, 40)
                return
            }
            when (lightMode) {
                "fire", "duo" -> {
                    // Brasa que respira y parpadea en el color elegido: a veces una
                    // punta muy brillante con el tono corrido hacia lo cálido
                    // (verde → amarillo-verde, rosa → rojo, azul → cian…), a veces
                    // cae a casi apagada.
                    fireLevel += (rnd.nextFloat() - 0.5f) * 0.55f * fireHeat
                    if (rnd.nextFloat() < 0.06f * fireHeat) fireLevel = 1f
                    if (rnd.nextFloat() < 0.04f) fireLevel = 0.15f
                    fireLevel = fireLevel.coerceIn(0.1f, 1f)
                    // "duo": cada ~380 ms cambia de color (rojo ↔ azul en SPORT).
                    val duo = lightMode == "duo"
                    Color.colorToHSV(if (duo && (now / 380) % 2 == 1L) fireColor2 else fireColor, hsv)
                    val peak = if (duo) 0f else ((fireLevel - 0.75f) / 0.25f).coerceIn(0f, 1f)
                    val toWarm = ((60f - hsv[0] + 540f) % 360f) - 180f   // camino corto hacia el amarillo
                    val h = (hsv[0] + toWarm.coerceIn(-30f * peak, 30f * peak) + 360f) % 360f
                    val sat = hsv[1] * (1f - 0.25f * peak)
                    val v = 0.12f + 0.88f * fireLevel
                    setLightColor(Color.HSVToColor(floatArrayOf(h, sat, v)))
                    main.postDelayed(this, firePeriod)
                }
                // Fijo/apagado también se reenvía: Android a veces le vuelve a poner
                // al mando su color de jugador y un solo envío se perdía.
                "solid" -> {
                    setLightColor(solidColor)
                    main.postDelayed(this, 1000)
                }
                else -> {
                    setLightColor(Color.BLACK)
                    main.postDelayed(this, 1500)
                }
            }
        }
    }

    private fun restartLight() {
        main.removeCallbacks(lightTick)
        main.post(lightTick)
    }

    private fun setLightColor(c: Int) {
        setLight(Color.red(c), Color.green(c), Color.blue(c))
    }

    private fun closeLights() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            try { lightsSession?.close() } catch (_: Exception) {}
        }
        lightsSession = null
        lightsDeviceId = -1
    }

    @Suppress("DEPRECATION")
    private fun rumble(ms: Long, amp: Int): Boolean {
        return try {
            val d = firstGamepad() ?: return false
            val v = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) d.vibratorManager.defaultVibrator else d.vibrator
            if (!v.hasVibrator()) return false
            v.vibrate(VibrationEffect.createOneShot(ms, amp.coerceIn(1, 255)))
            true
        } catch (e: Exception) {
            false
        }
    }
}
