import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../services/voice_command_parser.dart';
import '../widgets/common.dart';
import '../widgets/top_bar.dart';

/// Glosario de comandos de voz: qué frases reconoce la app y qué hace
/// cada una. Los datos vienen de `voiceCommandGlossary` (un solo lugar,
/// junto al parser real, para que esta lista nunca se desincronice).
class VoiceCommandsHelpScreen extends StatelessWidget {
  const VoiceCommandsHelpScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final byCategory = <String, List<VoiceCommandDoc>>{};
    for (final doc in voiceCommandGlossary) {
      byCategory.putIfAbsent(doc.category, () => []).add(doc);
    }

    // Scaffold es necesario aquí: esta pantalla se abre con Navigator.push
    // (no vive dentro del Scaffold único de RootShell), así que sin el
    // suyo propio le falta el ancestro Material que le da al texto su
    // estilo real — sin él, Flutter cae en su estilo de emergencia
    // (amarillo y subrayado, a propósito, para que el bug se note).
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            ScreenTopBar(
              title: 'Comandos de voz',
              onBack: () => Navigator.of(context).pop(),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 18),
                children: [
                  const Text(
                    'Toca el micrófono en Control y di cualquiera de estas frases. Lo que no '
                    'calce con ninguna se le pregunta a Gemini junto con una foto actual de la cámara.',
                    style: TextStyle(
                      fontSize: 12.5,
                      color: AppColors.text2,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  for (final category in byCategory.keys) ...[
                    SectionTitle(category),
                    AppCard(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 4,
                      ),
                      child: Column(
                        children: [
                          for (
                            var i = 0;
                            i < byCategory[category]!.length;
                            i++
                          ) ...[
                            _CommandRow(doc: byCategory[category]![i]),
                            if (i != byCategory[category]!.length - 1)
                              const Divider(
                                height: 1,
                                color: AppColors.lineSoft,
                              ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CommandRow extends StatelessWidget {
  final VoiceCommandDoc doc;
  const _CommandRow({required this.doc});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: doc.examples
                .map(
                  (e) => Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.orangeDim,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '"$e"',
                      style: const TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        color: AppColors.orange,
                      ),
                    ),
                  ),
                )
                .toList(),
          ),
          const SizedBox(height: 6),
          Text(
            doc.description,
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
