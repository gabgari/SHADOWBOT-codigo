import 'dart:typed_data';

import 'package:google_generative_ai/google_generative_ai.dart';

import 'gemini_api_key_store.dart';

/// Error de alto nivel para mostrar en la UI. El mensaje NUNCA incluye la
/// API Key (ver regla "NO incluirla en mensajes de error" de MEJORAS.md).
class GeminiException implements Exception {
  final String message;
  GeminiException(this.message);
  @override
  String toString() => message;
}

/// Un intercambio completo con Gemini (para la pantalla "Log de Gemini").
/// Nada acotado/recortado aquí — es justo para poder ver el error o la
/// respuesta tal cual llegó cuando algo no cuadra.
class GeminiLogEntry {
  final DateTime time;
  final String model;
  final String prompt;
  final bool ok;
  final String result; // respuesta completa, o el mensaje de error completo
  final int? latencyMs;
  const GeminiLogEntry({
    required this.time,
    required this.model,
    required this.prompt,
    required this.ok,
    required this.result,
    this.latencyMs,
  });
}

/// Único punto de contacto con la API de Gemini (Vision + preguntas de
/// texto). Nada de HTTP a Gemini se hace fuera de esta clase — así lo pide
/// MEJORAS.md ("no dispersar llamadas HTTP de Gemini por diferentes
/// widgets").
///
/// Usa el SDK oficial `google_generative_ai`. La API key se lee de
/// [GeminiApiKeyStore] (Keystore/Keychain), configurable desde
/// Sistema > Asistente IA.
class GeminiService {
  // "-latest" en vez de una versión fija (p.ej. "gemini-2.5-flash"): Google
  // va retirando versiones con el tiempo y ese nombre específico empezó a
  // fallar con "model not found/no longer supported". El alias siempre
  // apunta al flash multimodal vigente, así no se vuelve a romper solo.
  static const _modelName = 'gemini-flash-latest';
  static const _timeout = Duration(seconds: 25);

  GenerativeModel? _model;
  String? _loadedApiKey;

  final List<GeminiLogEntry> _log = [];
  List<GeminiLogEntry> get log => List.unmodifiable(_log);
  void clearLog() => _log.clear();

  void _addLog(String prompt, {required bool ok, required String result, int? latencyMs}) {
    _log.insert(0, GeminiLogEntry(time: DateTime.now(), model: _modelName, prompt: prompt, ok: ok, result: result, latencyMs: latencyMs));
    if (_log.length > 30) _log.removeLast();
  }

  Future<bool> get isConfigured async => (await GeminiApiKeyStore.instance.read()) != null;

  Future<GenerativeModel> _getModel() async {
    final apiKey = await GeminiApiKeyStore.instance.read();
    if (apiKey == null) {
      throw GeminiException('Falta configurar la API Key de Gemini (Sistema > Asistente IA).');
    }
    if (_model == null || _loadedApiKey != apiKey) {
      _model = GenerativeModel(model: _modelName, apiKey: apiKey);
      _loadedApiKey = apiKey;
    }
    return _model!;
  }

  /// Llama a Gemini con la imagen actual de la cámara + un prompt.
  /// [prompt] por defecto pide una descripción breve; para preguntas del
  /// usuario ("¿hay un obstáculo?") se pasa la pregunta tal cual.
  Future<String> analyzeImage(Uint8List jpegBytes, {String prompt = _defaultPrompt}) async {
    final sw = Stopwatch()..start();
    try {
      final model = await _getModel();
      final content = [
        Content.multi([
          TextPart(prompt),
          DataPart('image/jpeg', jpegBytes),
        ]),
      ];
      final res = await model.generateContent(content).timeout(_timeout);
      final text = res.text?.trim();
      if (text == null || text.isEmpty) {
        throw GeminiException('Gemini no devolvió una respuesta.');
      }
      sw.stop();
      _addLog(prompt, ok: true, result: text, latencyMs: sw.elapsedMilliseconds);
      return text;
    } on GeminiException catch (e) {
      sw.stop();
      _addLog(prompt, ok: false, result: e.message, latencyMs: sw.elapsedMilliseconds);
      rethrow;
    } on GenerativeAIException catch (e) {
      sw.stop();
      // e.message viene directo del servidor de Google (nunca incluye la
      // API Key) — es más útil que adivinar por texto libre, así que se
      // muestra tal cual en vez de un mensaje genérico.
      _addLog(prompt, ok: false, result: e.message, latencyMs: sw.elapsedMilliseconds);
      throw GeminiException(e.message);
    } catch (e) {
      sw.stop();
      final msg = _friendlyError(e);
      _addLog(prompt, ok: false, result: msg, latencyMs: sw.elapsedMilliseconds);
      throw GeminiException(msg);
    }
  }

  static const _defaultPrompt =
      'Describe brevemente y en español, en 1-2 frases, lo que se ve en esta imagen tomada por la cámara de un vehículo robot.';

  String _friendlyError(Object e) {
    final s = e.toString();
    if (s.contains('TimeoutException')) return 'Gemini tardó demasiado en responder (timeout).';
    if (s.contains('API_KEY') || s.contains('API key') || s.contains('401') || s.contains('403')) {
      return 'La API Key de Gemini no es válida. Revísala en Sistema > Asistente IA.';
    }
    if (s.contains('SocketException') || s.contains('Failed host lookup')) {
      return 'Sin conexión a Internet para llegar a Gemini.';
    }
    // Última opción: mostrar el error real (acotado) en vez de un mensaje
    // genérico que no ayuda a diagnosticar — nunca contiene la API Key,
    // eso solo vive en GeminiApiKeyStore y nunca se imprime ni se adjunta
    // a una excepción.
    final trimmed = s.length > 180 ? '${s.substring(0, 180)}…' : s;
    return 'No se pudo obtener respuesta de Gemini: $trimmed';
  }
}
