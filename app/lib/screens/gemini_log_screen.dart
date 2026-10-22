import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../services/gemini_service.dart';
import '../widgets/common.dart';
import '../widgets/top_bar.dart';

/// Log completo de los intercambios con Gemini (prompt enviado + respuesta
/// u error, tal cual, sin recortar) — para poder diagnosticar cuando algo
/// falla sin adivinar. Vive en memoria (`GeminiService.log`), se vacía al
/// cerrar la app.
class GeminiLogScreen extends StatefulWidget {
  final GeminiService geminiService;
  const GeminiLogScreen({super.key, required this.geminiService});

  @override
  State<GeminiLogScreen> createState() => _GeminiLogScreenState();
}

class _GeminiLogScreenState extends State<GeminiLogScreen> {
  @override
  Widget build(BuildContext context) {
    final entries = widget.geminiService.log;
    // Scaffold es necesario: esta pantalla se abre con Navigator.push, no
    // vive dentro del Scaffold de RootShell — sin el suyo propio, el texto
    // pierde el ancestro Material y Flutter lo pinta con su estilo de
    // emergencia (amarillo subrayado, a propósito, para delatar el bug).
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            ScreenTopBar(
              title: 'Log de Gemini',
              onBack: () => Navigator.of(context).pop(),
            ),
            Expanded(
              child: entries.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.symmetric(horizontal: 32),
                        child: Text(
                          'Todavía no hay ninguna llamada a Gemini en esta sesión. Usa '
                          '"Analizar" o hazle una pregunta por voz y vuelve aquí.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: AppColors.text3,
                            fontSize: 12.5,
                          ),
                        ),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(20, 4, 20, 18),
                      itemCount: entries.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 10),
                      itemBuilder: (context, i) => _LogCard(entry: entries[i]),
                    ),
            ),
            if (entries.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                child: GhostButton(
                  label: 'Borrar log',
                  onPressed: () =>
                      setState(() => widget.geminiService.clearLog()),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _LogCard extends StatelessWidget {
  final GeminiLogEntry entry;
  const _LogCard({required this.entry});

  String _fmtTime(DateTime t) {
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    final s = t.second.toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final color = entry.ok ? AppColors.green : AppColors.red;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 6),
              Text(
                entry.ok ? 'OK' : 'ERROR',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: color,
                ),
              ),
              const Spacer(),
              Text(
                _fmtTime(entry.time),
                style: const TextStyle(
                  fontSize: 10.5,
                  color: AppColors.text3,
                  fontFamily: 'JetBrainsMono',
                ),
              ),
              if (entry.latencyMs != null) ...[
                const SizedBox(width: 8),
                Text(
                  '${entry.latencyMs} ms',
                  style: const TextStyle(
                    fontSize: 10.5,
                    color: AppColors.text3,
                    fontFamily: 'JetBrainsMono',
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 6),
          Text(
            entry.model,
            style: const TextStyle(
              fontSize: 10,
              color: AppColors.text3,
              fontFamily: 'JetBrainsMono',
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'PROMPT',
            style: TextStyle(
              fontSize: 9.5,
              fontWeight: FontWeight.w700,
              color: AppColors.text3,
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(height: 3),
          SelectableText(
            entry.prompt,
            style: const TextStyle(fontSize: 12, color: AppColors.text1),
          ),
          const SizedBox(height: 8),
          Text(
            entry.ok ? 'RESPUESTA' : 'ERROR COMPLETO',
            style: TextStyle(
              fontSize: 9.5,
              fontWeight: FontWeight.w700,
              color: color,
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(height: 3),
          SelectableText(
            entry.result,
            style: const TextStyle(
              fontSize: 12,
              color: AppColors.text1,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}
