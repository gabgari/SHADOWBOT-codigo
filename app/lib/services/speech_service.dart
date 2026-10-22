import 'package:speech_to_text/speech_to_text.dart' as stt;

/// Reconocimiento de voz con el micrófono del teléfono (nunca un micrófono
/// físico en el vehículo, ver MEJORAS.md). Envuelve `speech_to_text` para
/// que la lógica de permisos/inicialización no viva en los widgets.
class SpeechService {
  final stt.SpeechToText _speech = stt.SpeechToText();
  bool _available = false;
  bool _initTried = false;

  bool get isListening => _speech.isListening;

  /// Pide permiso de micrófono e inicializa el motor de reconocimiento.
  /// Devuelve `false` si el usuario negó el permiso o el teléfono no tiene
  /// reconocimiento de voz disponible.
  Future<bool> initialize({void Function(String error)? onError}) async {
    if (_initTried) return _available;
    _initTried = true;
    try {
      _available = await _speech.initialize(
        onError: (e) => onError?.call(e.errorMsg),
        onStatus: (_) {},
      );
    } catch (e) {
      _available = false;
      onError?.call(e.toString());
    }
    return _available;
  }

  /// Empieza a escuchar. [onResult] recibe el texto reconocido cada vez que
  /// se actualiza (parcial y final); [onDone] se llama cuando el motor deja
  /// de escuchar (silencio, timeout, o `stopListening()`).
  Future<void> startListening({
    required void Function(String text, bool isFinal) onResult,
    required void Function() onDone,
    String localeId = 'es_ES',
  }) async {
    if (!_available) return;
    await _speech.listen(
      onResult: (result) => onResult(result.recognizedWords, result.finalResult),
      listenOptions: stt.SpeechListenOptions(
        listenMode: stt.ListenMode.confirmation,
        cancelOnError: true,
        partialResults: true,
        listenFor: const Duration(seconds: 12),
        pauseFor: const Duration(seconds: 3),
        localeId: localeId,
      ),
    );
    // El plugin no siempre dispara un callback explícito de "terminado";
    // se vigila el propio estado del motor.
    _watchUntilDone(onDone);
  }

  void _watchUntilDone(void Function() onDone) async {
    while (_speech.isListening) {
      await Future.delayed(const Duration(milliseconds: 200));
    }
    onDone();
  }

  Future<void> stopListening() => _speech.stop();

  Future<void> cancel() => _speech.cancel();
}
