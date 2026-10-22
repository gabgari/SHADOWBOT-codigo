import 'package:flutter_tts/flutter_tts.dart';

/// Texto a voz por la bocina del teléfono (nunca hardware de audio del
/// vehículo, ver MEJORAS.md). Envuelve `flutter_tts` para que ningún
/// widget hable directo con el plugin.
class TtsService {
  final FlutterTts _tts = FlutterTts();
  bool _ready = false;

  Future<void> _ensureReady() async {
    if (_ready) return;
    _ready = true;
    try {
      // Preferir una voz en español si el teléfono tiene alguna instalada.
      final languages = await _tts.getLanguages;
      final esLang = (languages is List)
          ? languages.cast<Object?>().map((e) => e.toString()).firstWhere(
                (l) => l.toLowerCase().startsWith('es'),
                orElse: () => '',
              )
          : '';
      await _tts.setLanguage(esLang.isNotEmpty ? esLang : 'es-ES');
    } catch (_) {
      // Si falla la detección de idioma, se sigue con el default del motor TTS.
    }
    await _tts.setSpeechRate(0.5);
    await _tts.setVolume(1.0);
    await _tts.setPitch(1.0);
    // Evita que se amontonen respuestas: cada speak() cancela la anterior.
    await _tts.awaitSpeakCompletion(true);
  }

  Future<void> speak(String text) async {
    if (text.trim().isEmpty) return;
    await _ensureReady();
    await stop();
    await _tts.speak(text);
  }

  Future<void> stop() => _tts.stop();
}
