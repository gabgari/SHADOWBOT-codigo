import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_theme.dart';
import '../services/gemini_api_key_store.dart';
import '../state/assistant_state.dart';
import '../widgets/common.dart';
import '../widgets/top_bar.dart';
import 'gemini_log_screen.dart';

/// Configuración de la API Key de Gemini (Sistema > Asistente IA). Se
/// guarda en almacenamiento seguro del sistema (`GeminiApiKeyStore`) — no
/// queda en SharedPreferences en texto plano ni se imprime en logs.
class GeminiSettingsScreen extends StatefulWidget {
  const GeminiSettingsScreen({super.key});

  @override
  State<GeminiSettingsScreen> createState() => _GeminiSettingsScreenState();
}

class _GeminiSettingsScreenState extends State<GeminiSettingsScreen> {
  final _controller = TextEditingController();
  bool _obscure = true;
  bool _loading = true;
  bool _saving = false;
  bool _hasKey = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final key = await GeminiApiKeyStore.instance.read();
    if (!mounted) return;
    setState(() {
      _hasKey = key != null;
      _controller.text = key ?? '';
      _loading = false;
    });
  }

  Future<void> _save() async {
    final value = _controller.text.trim();
    if (value.isEmpty) {
      showAppToast(context, 'Escribe una API Key antes de guardar');
      return;
    }
    setState(() => _saving = true);
    await GeminiApiKeyStore.instance.write(value);
    if (!mounted) return;
    setState(() {
      _saving = false;
      _hasKey = true;
    });
    showAppToast(context, 'API Key de Gemini guardada');
  }

  Future<void> _clear() async {
    await GeminiApiKeyStore.instance.clear();
    if (!mounted) return;
    setState(() {
      _controller.clear();
      _hasKey = false;
    });
    showAppToast(context, 'API Key eliminada');
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Scaffold es necesario: esta pantalla se abre con Navigator.push, no
    // vive dentro del Scaffold de RootShell — sin el suyo propio, el texto
    // pierde el ancestro Material y Flutter lo pinta con su estilo de
    // emergencia (amarillo subrayado, a propósito, para delatar el bug).
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            ScreenTopBar(
              title: 'Asistente IA',
              onBack: () => Navigator.of(context).pop(),
            ),
            Expanded(
              child: _loading
                  ? const Center(
                      child: CircularProgressIndicator(color: AppColors.orange),
                    )
                  : ListView(
                      padding: const EdgeInsets.fromLTRB(20, 4, 20, 18),
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color:
                                (_hasKey ? AppColors.green : AppColors.yellow)
                                    .withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                _hasKey
                                    ? Icons.check_circle_rounded
                                    : Icons.info_outline_rounded,
                                size: 15,
                                color: _hasKey
                                    ? AppColors.green
                                    : AppColors.yellow,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                _hasKey
                                    ? 'API Key configurada'
                                    : 'Sin API Key — Gemini Vision y las preguntas de voz no funcionarán',
                                style: TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w600,
                                  color: _hasKey
                                      ? AppColors.green
                                      : AppColors.yellow,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SectionTitle('API Key de Gemini'),
                        AppCard(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              TextField(
                                controller: _controller,
                                obscureText: _obscure,
                                autocorrect: false,
                                enableSuggestions: false,
                                spellCheckConfiguration:
                                    const SpellCheckConfiguration.disabled(),
                                style: const TextStyle(
                                  color: AppColors.text1,
                                  fontSize: 13,
                                  fontFamily: 'JetBrainsMono',
                                ),
                                decoration: InputDecoration(
                                  hintText: 'AIza…',
                                  hintStyle: const TextStyle(
                                    color: AppColors.text3,
                                  ),
                                  filled: true,
                                  fillColor: AppColors.surface2,
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(10),
                                    borderSide: BorderSide.none,
                                  ),
                                  suffixIcon: IconButton(
                                    icon: Icon(
                                      _obscure
                                          ? Icons.visibility_rounded
                                          : Icons.visibility_off_rounded,
                                      color: AppColors.text3,
                                      size: 19,
                                    ),
                                    onPressed: () =>
                                        setState(() => _obscure = !_obscure),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 6),
                              const Text(
                                'Se guarda en el almacenamiento seguro del teléfono (Keystore/Keychain), no en texto plano.',
                                style: TextStyle(
                                  fontSize: 10.5,
                                  color: AppColors.text3,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                        PrimaryButton(
                          label: _saving ? 'Guardando…' : 'Guardar',
                          onPressed: _saving ? null : _save,
                        ),
                        if (_hasKey) ...[
                          const SizedBox(height: 10),
                          GhostButton(
                            label: 'Eliminar API Key',
                            onPressed: _clear,
                          ),
                        ],
                        const SizedBox(height: 10),
                        GhostButton(
                          label: 'Ver log de Gemini',
                          onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => GeminiLogScreen(
                                geminiService: context
                                    .read<AssistantState>()
                                    .geminiService,
                              ),
                            ),
                          ),
                        ),
                        const SectionTitle('¿Cómo consigo una API Key?'),
                        AppCard(
                          child: const Text(
                            '1. Entra a aistudio.google.com/apikey con tu cuenta de Google.\n'
                            '2. Crea una API Key gratuita (tiene cuota gratuita mensual).\n'
                            '3. Cópiala y pégala arriba.\n\n'
                            'Se usa para "Analizar" en la Cámara y para responder preguntas '
                            'por voz (p. ej. "¿qué estás viendo?"). Los comandos simples '
                            '("avanza 3 segundos", "detente", "enciende el led 2", "sube la '
                            'cámara", "toma una foto"…) NO usan Gemini — van directo a la '
                            'ESP32-S3 de control.',
                            style: TextStyle(
                              fontSize: 12,
                              color: AppColors.text2,
                              height: 1.5,
                            ),
                          ),
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
