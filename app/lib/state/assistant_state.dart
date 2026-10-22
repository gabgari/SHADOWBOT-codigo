import 'dart:async';

import 'package:flutter/foundation.dart';

import '../services/gemini_service.dart';
import '../services/speech_service.dart';
import '../services/tts_service.dart';
import '../services/voice_command_parser.dart';
import 'app_state.dart';

enum AssistantStatus { idle, listening, processing, speaking, error }

/// Orquesta Gemini Vision + TTS + comandos de voz sobre la arquitectura
/// existente (`AppState` ya sabe hablar con las 3 ESP32). Este estado NO
/// duplica esa comunicación: reutiliza `appState.pressMove`,
/// `appState.setArmAngles` (mismo camino que las barras del brazo),
/// `appState.setLed`/`appState.setAllLeds` y `appState.takePhoto()` para
/// comandos, y `appState.camService.capture()` para el frame que se le
/// manda a Gemini — el streaming (`/stream`) no se toca en absoluto.
class AssistantState extends ChangeNotifier {
  final AppState appState;
  final GeminiService geminiService;
  final TtsService ttsService;
  final SpeechService speechService;

  AssistantState({
    required this.appState,
    GeminiService? geminiService,
    TtsService? ttsService,
    SpeechService? speechService,
  })  : geminiService = geminiService ?? GeminiService(),
        ttsService = ttsService ?? TtsService(),
        speechService = speechService ?? SpeechService();

  AssistantStatus status = AssistantStatus.idle;
  String transcript = '';
  String lastResponse = '';
  String? errorMessage;
  bool _micInitialized = false;

  // Movimiento por tiempo ("avanza 3 segundos"): cada comando de
  // movimiento nuevo (incluido "detente") invalida cualquier ciclo de
  // reenvío pendiente, para poder interrumpirlo a mitad de camino.
  int _moveGeneration = 0;

  bool get isBusy => status == AssistantStatus.processing || status == AssistantStatus.speaking;

  // ---------------- Botón "Analizar" (Gemini Vision) ----------------

  /// Captura el frame actual de la cámara (`/capture`, sin tocar el
  /// streaming) y le pide a Gemini una descripción. Muestra el texto y lo
  /// lee por la bocina del teléfono.
  Future<void> analyzeCurrentFrame() => _askGemini(null);

  // ---------------- Botón de micrófono ----------------

  Future<void> toggleMic() async {
    if (status == AssistantStatus.listening) {
      await speechService.stopListening();
      return;
    }
    // "processing"/"speaking" NO bloquean el mic si lo que está en curso es
    // solo un movimiento por tiempo (ver _executeControlCommand) — eso deja
    // status en idle a propósito para poder interrumpirlo con la voz.
    if (isBusy) return;

    errorMessage = null;
    if (!_micInitialized) {
      final ok = await speechService.initialize(onError: _onMicError);
      _micInitialized = true;
      if (!ok) {
        _onMicError('Micrófono no disponible o permiso denegado.');
        return;
      }
    }

    transcript = '';
    lastResponse = '';
    status = AssistantStatus.listening;
    notifyListeners();

    await speechService.startListening(
      onResult: (text, isFinal) {
        transcript = text;
        notifyListeners();
      },
      onDone: _onListeningDone,
    );
  }

  void _onMicError(String message) {
    errorMessage = message;
    status = AssistantStatus.error;
    notifyListeners();
  }

  Future<void> _onListeningDone() async {
    if (status != AssistantStatus.listening) return; // ya se movió a error, etc.
    final text = transcript.trim();
    if (text.isEmpty) {
      status = AssistantStatus.idle;
      notifyListeners();
      return;
    }
    await _process(text);
  }

  Future<void> _process(String text) async {
    final intent = parseVoiceCommand(text);
    switch (intent) {
      case MoveIntent() || ArmIntent() || LedIntent() || PhotoIntent():
        status = AssistantStatus.processing;
        notifyListeners();
        await _executeControlCommand(intent);
        status = AssistantStatus.idle;
        notifyListeners();
      case AiQuestionIntent(:final question):
        await _askGemini(question);
      case EmptyIntent():
        status = AssistantStatus.idle;
        notifyListeners();
    }
  }

  /// Comandos de control: van DIRECTO a la ESP32-S3 (mismo camino que ya
  /// usan D-pad/ArmPad/botón de foto) — nunca pasan por Gemini.
  Future<void> _executeControlCommand(VoiceIntent intent) async {
    switch (intent) {
      case MoveIntent(:final wireDir, :final duration):
        _moveGeneration++; // cancela cualquier movimiento por tiempo anterior
        if (duration == null || wireDir == 'detener') {
          await appState.pressMove(wireDir);
        } else {
          // No se espera aquí (fire-and-forget): así el asistente vuelve a
          // "idle" de inmediato y se puede interrumpir por voz a mitad de
          // camino (ver toggleMic/_moveGeneration).
          unawaited(_moveForDuration(wireDir, duration));
        }
      case ArmIntent(:final wireDir):
        _applyArmVoice(wireDir);
      case LedIntent(:final indices, :final all, :final on):
        if (all) {
          await appState.setAllLeds(on);
        } else {
          for (final i in indices) {
            await appState.setLed(i, on);
          }
        }
      case PhotoIntent():
        await appState.takePhoto();
      case AiQuestionIntent() || EmptyIntent():
        break; // no debería llegar aquí, ver _process
    }
  }

  /// Mueve el brazo por voz usando el MISMO estado que las barras
  /// deslizables (`appState.armPan/armTilt` + `setArmAngles`) — antes esto
  /// llamaba a `pressArm` (pasos relativos por `/arm`), que ya no tiene
  /// nada conectado en la interfaz desde que el brazo pasó a ser barras de
  /// porcentaje: la ESP32 sí se movía, pero las barras se quedaban quietas
  /// y no quedaba ningún registro de la posición real.
  static const _armVoiceStep = 12; // % por comando de voz

  void _applyArmVoice(String wireDir) {
    int pan = appState.armPan;
    int tilt = appState.armTilt;
    switch (wireDir) {
      case 'arriba':
        tilt = (tilt + _armVoiceStep).clamp(0, 100);
      case 'abajo':
        tilt = (tilt - _armVoiceStep).clamp(0, 100);
      case 'izquierda':
        pan = (pan - _armVoiceStep).clamp(0, 100);
      case 'derecha':
        pan = (pan + _armVoiceStep).clamp(0, 100);
      case 'centro':
        pan = 50;
        tilt = 50;
    }
    appState.setArmAngles(pan, tilt);
  }

  /// Reenvía [wireDir] cada 400ms (bien por debajo del watchdog de 800ms
  /// de la ESP32) durante [duration], y frena al terminar. Se corta antes
  /// si llega otro comando de movimiento (incluido "detente") mientras
  /// tanto — ver `_moveGeneration`.
  Future<void> _moveForDuration(String wireDir, Duration duration) async {
    final myGeneration = _moveGeneration;
    final steps = (duration.inMilliseconds / 400).ceil();
    for (var i = 0; i < steps; i++) {
      if (myGeneration != _moveGeneration) return;
      await appState.pressMove(wireDir);
      await Future.delayed(const Duration(milliseconds: 400));
    }
    if (myGeneration == _moveGeneration) {
      await appState.pressMove('detener');
    }
  }

  /// Captura un frame de la cámara que el usuario haya elegido como fuente
  /// para la IA (`appState.aiCameraSource`, ver Cámara > "IA observa") —
  /// ESP32-CAM vía `/capture` o Tapo C110 vía screenshot del reproductor
  /// RTSP. Mismo tipo de resultado (JPEG) en ambos casos, así que el resto
  /// de `_askGemini` no necesita saber de cuál vino.
  Future<Uint8List?> _captureActiveFrame() async {
    if (appState.aiCameraSource == AiCameraSource.tapoCam) {
      return appState.tapoCamService.captureFrame();
    }
    final raw = await appState.camService.capture();
    return raw == null ? null : Uint8List.fromList(raw);
  }

  /// Preguntas de IA (o el botón "Analizar", con [question] null): captura
  /// un frame y llama a Gemini. [question] null usa el prompt genérico de
  /// descripción; si no, se le pasa la pregunta del usuario tal cual.
  Future<void> _askGemini(String? question) async {
    errorMessage = null;
    lastResponse = '';
    status = AssistantStatus.processing;
    notifyListeners();
    try {
      final bytes = await _captureActiveFrame();
      if (bytes == null) {
        final camName = appState.aiCameraSource == AiCameraSource.tapoCam ? 'CAM 2' : 'CAM 1';
        throw GeminiException('No se pudo obtener una imagen de la cámara ($camName) — sin vincular o sin respuesta.');
      }
      final text = question == null
          ? await geminiService.analyzeImage(bytes)
          : await geminiService.analyzeImage(bytes, prompt: '$question Responde en español, breve (1-3 frases).');
      lastResponse = text;
      status = AssistantStatus.speaking;
      notifyListeners();
      await ttsService.speak(text);
      status = AssistantStatus.idle;
      notifyListeners();
    } catch (e) {
      errorMessage = e is GeminiException ? e.message : 'No se pudo completar la solicitud a Gemini.';
      status = AssistantStatus.error;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    speechService.cancel();
    ttsService.stop();
    super.dispose();
  }
}
