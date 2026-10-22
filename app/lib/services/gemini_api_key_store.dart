import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Guarda la API Key de Gemini en almacenamiento seguro del sistema
/// (Keystore en Android / Keychain en iOS/macOS) en vez de SharedPreferences
/// en texto plano. Es un solo punto de lectura/escritura para que la key
/// nunca se copie a otros archivos.
///
/// Nunca se imprime en logs ni se incluye en mensajes de error (ver
/// `GeminiService`, que solo reporta "sin API key configurada").
class GeminiApiKeyStore {
  GeminiApiKeyStore._();
  static final GeminiApiKeyStore instance = GeminiApiKeyStore._();

  static const _key = 'gemini_api_key';
  final _storage = const FlutterSecureStorage();

  Future<String?> read() async {
    try {
      final v = await _storage.read(key: _key);
      return (v == null || v.isEmpty) ? null : v;
    } catch (_) {
      return null; // almacenamiento seguro no disponible (p.ej. web sin config) -> sin key
    }
  }

  Future<void> write(String apiKey) async {
    await _storage.write(key: _key, value: apiKey.trim());
  }

  Future<void> clear() async {
    await _storage.delete(key: _key);
  }
}
