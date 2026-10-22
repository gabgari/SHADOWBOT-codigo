/// Intents que puede producir una frase reconocida por voz. Todo lo que
/// sea un comando de control (mover, brazo, LEDs, foto) se ejecuta local y
/// directo a la ESP32 — nunca pasa por Gemini (ver MEJORAS.md). Cualquier
/// frase que no calce con ningún comando se trata como pregunta de IA.
sealed class VoiceIntent {
  const VoiceIntent();
}

/// Mover el carrito. [duration] es cuánto tiempo mantenerlo en movimiento
/// (ej. "avanza 3 segundos"); `null` = un solo pulso, como un tap del
/// D-pad (la ESP32 lo frena sola a los 800ms si no llega nada más).
class MoveIntent extends VoiceIntent {
  final String wireDir; // adelante | atras | izquierda | derecha | detener
  final Duration? duration;
  const MoveIntent(this.wireDir, {this.duration});
}

/// Mover el brazo pan/tilt de 2 ejes donde va la cámara.
class ArmIntent extends VoiceIntent {
  final String wireDir; // arriba | abajo | izquierda | derecha | centro
  const ArmIntent(this.wireDir);
}

/// Encender/apagar uno o varios de los 4 LEDs. [all] enciende/apaga los 4.
class LedIntent extends VoiceIntent {
  final Set<int> indices; // 1-4
  final bool all;
  final bool on;
  const LedIntent({required this.indices, required this.all, required this.on});
}

/// "toma una foto" -> captura desde la ESP32-CAM y la guarda en la galería
/// de la app (mismo botón que "Tomar foto").
class PhotoIntent extends VoiceIntent {
  const PhotoIntent();
}

class AiQuestionIntent extends VoiceIntent {
  final String question;
  const AiQuestionIntent(this.question);
}

class EmptyIntent extends VoiceIntent {
  const EmptyIntent();
}

String _normalize(String s) {
  var out = s.toLowerCase().trim();
  const accents = {'á': 'a', 'é': 'e', 'í': 'i', 'ó': 'o', 'ú': 'u', 'ñ': 'n', 'ü': 'u'};
  accents.forEach((a, b) => out = out.replaceAll(a, b));
  return out;
}

bool _hasWord(String text, String word) => RegExp('(^|[^a-z0-9])$word([^a-z0-9]|\$)').hasMatch(text);
bool _hasAny(String text, List<String> words) => words.any((w) => w.contains(' ') ? text.contains(w) : _hasWord(text, w));

// Números hablados 1-20 -> dígito, para "avanza tres segundos" o
// "enciende el led dos" cuando el reconocedor de voz no los transcribe ya
// como dígitos.
const _numberWords = {
  'uno': '1', 'una': '1', 'dos': '2', 'tres': '3', 'cuatro': '4', 'cinco': '5',
  'seis': '6', 'siete': '7', 'ocho': '8', 'nueve': '9', 'diez': '10',
  'once': '11', 'doce': '12', 'trece': '13', 'catorce': '14', 'quince': '15',
  'dieciseis': '16', 'diecisiete': '17', 'dieciocho': '18', 'diecinueve': '19', 'veinte': '20',
};

String _wordsToDigits(String text) {
  var out = text;
  _numberWords.forEach((word, digit) {
    out = out.replaceAll(RegExp('(^|[^a-z0-9])$word([^a-z0-9]|\$)'), ' $digit ');
  });
  return out;
}

List<int> _extractNumbers(String text) {
  final withDigits = _wordsToDigits(text);
  return RegExp(r'\d+').allMatches(withDigits).map((m) => int.parse(m.group(0)!)).toList();
}

// Tope de seguridad: una orden de voz mal entendida ("avanza 300
// segundos") nunca debe dejar el carrito moviéndose sin control.
const _maxMoveSeconds = 15;

VoiceIntent parseVoiceCommand(String rawText) {
  final text = _normalize(rawText);
  if (text.isEmpty) return const EmptyIntent();

  // ---- Foto ----
  if (_hasAny(text, ['foto', 'captura una imagen', 'toma una captura'])) {
    return const PhotoIntent();
  }

  // ---- Brazo / cámara (2 ejes) ----
  // Requiere mencionar "camara", "brazo" o "servo" para no chocar con los
  // mismos verbos de mover el carrito ("izquierda"/"derecha"/"arriba").
  if (_hasAny(text, ['camara', 'brazo', 'servo'])) {
    if (_hasAny(text, ['centra', 'centrar', 'al centro', 'centro'])) return const ArmIntent('centro');
    if (_hasAny(text, ['sube', 'arriba', 'inclina arriba'])) return const ArmIntent('arriba');
    if (_hasAny(text, ['baja', 'abajo', 'inclina abajo'])) return const ArmIntent('abajo');
    if (_hasAny(text, ['izquierda'])) return const ArmIntent('izquierda');
    if (_hasAny(text, ['derecha'])) return const ArmIntent('derecha');
    // Mencionó cámara/brazo/servo pero sin dirección clara (p.ej. "mira la
    // cámara") -> se trata como pregunta de IA en vez de ignorarlo.
  }

  // ---- LEDs (individuales o combinados) ----
  if (_hasAny(text, ['led', 'leds', 'luz', 'luces'])) {
    final on = _hasAny(text, ['enciende', 'prende', 'activa', 'encendidas', 'encendido']);
    final off = _hasAny(text, ['apaga', 'desactiva', 'apagadas', 'apagado']);
    if (on || off) {
      final all = _hasAny(text, ['todos', 'todas']);
      // Compatibilidad con los alias de color de antes (LED1=rojo,
      // LED2=azul, LED3=verde) además de los números directos "led 2".
      final indices = <int>{..._extractNumbers(text).where((n) => n >= 1 && n <= 4)};
      if (_hasWord(text, 'roja') || _hasWord(text, 'rojo')) indices.add(1);
      if (_hasWord(text, 'azul')) indices.add(2);
      if (_hasWord(text, 'verde')) indices.add(3);
      if (all || indices.isNotEmpty) {
        return LedIntent(indices: indices, all: all, on: on);
      }
      // Dijo "enciende/apaga las luces" sin número ni color -> los 4.
      return LedIntent(indices: const {}, all: true, on: on);
    }
  }

  // ---- Movimiento del carrito (con o sin duración en segundos) ----
  Duration? duration;
  final secondsMatch = RegExp(r'(\d+)\s*segund').firstMatch(_wordsToDigits(text));
  if (secondsMatch != null) {
    final secs = int.parse(secondsMatch.group(1)!).clamp(1, _maxMoveSeconds);
    duration = Duration(seconds: secs);
  }

  if (_hasAny(text, ['detente', 'detenete', 'alto', 'para', 'frena', 'stop'])) {
    return const MoveIntent('detener');
  }
  if (_hasAny(text, ['avanza', 'adelante', 'avanzar'])) {
    return MoveIntent('adelante', duration: duration);
  }
  if (_hasAny(text, ['retrocede', 'retroceder', 'reversa', 'hacia atras', 'atras'])) {
    return MoveIntent('atras', duration: duration);
  }
  if (_hasAny(text, ['gira a la izquierda', 'izquierda'])) {
    return MoveIntent('izquierda', duration: duration);
  }
  if (_hasAny(text, ['gira a la derecha', 'derecha'])) {
    return MoveIntent('derecha', duration: duration);
  }

  return AiQuestionIntent(rawText.trim());
}

/// Una entrada del glosario de comandos (ver `VoiceCommandsHelpScreen`).
/// Documenta a mano lo que hace [parseVoiceCommand] arriba — si agregas o
/// cambias una frase reconocida, actualiza también esta lista.
class VoiceCommandDoc {
  final String category;
  final List<String> examples;
  final String description;
  const VoiceCommandDoc({required this.category, required this.examples, required this.description});
}

const List<VoiceCommandDoc> voiceCommandGlossary = [
  VoiceCommandDoc(
    category: 'Movimiento',
    examples: ['avanza', 'adelante'],
    description: 'Mueve el carrito hacia adelante.',
  ),
  VoiceCommandDoc(
    category: 'Movimiento',
    examples: ['retrocede', 'atrás', 'reversa'],
    description: 'Mueve el carrito hacia atrás.',
  ),
  VoiceCommandDoc(
    category: 'Movimiento',
    examples: ['izquierda', 'gira a la izquierda'],
    description: 'Gira/curva el carrito hacia la izquierda.',
  ),
  VoiceCommandDoc(
    category: 'Movimiento',
    examples: ['derecha', 'gira a la derecha'],
    description: 'Gira/curva el carrito hacia la derecha.',
  ),
  VoiceCommandDoc(
    category: 'Movimiento',
    examples: ['detente', 'alto', 'para', 'frena'],
    description: 'Detiene el carrito de inmediato.',
  ),
  VoiceCommandDoc(
    category: 'Movimiento por tiempo',
    examples: ['avanza 3 segundos', 'retrocede 5 segundos'],
    description:
        'Se mueve exactamente ese tiempo (máximo 15 segundos por seguridad) y se detiene sola. '
        'Decir "detente" a la mitad la corta antes.',
  ),
  VoiceCommandDoc(
    category: 'Brazo de la cámara',
    examples: ['sube la cámara', 'brazo arriba'],
    description: 'Inclina el brazo hacia arriba. Hay que mencionar "cámara", "brazo" o "servo" en la frase.',
  ),
  VoiceCommandDoc(
    category: 'Brazo de la cámara',
    examples: ['baja la cámara', 'brazo abajo'],
    description: 'Inclina el brazo hacia abajo.',
  ),
  VoiceCommandDoc(
    category: 'Brazo de la cámara',
    examples: ['mueve la cámara a la izquierda'],
    description: 'Gira el brazo hacia la izquierda.',
  ),
  VoiceCommandDoc(
    category: 'Brazo de la cámara',
    examples: ['mueve la cámara a la derecha'],
    description: 'Gira el brazo hacia la derecha.',
  ),
  VoiceCommandDoc(
    category: 'Brazo de la cámara',
    examples: ['centra la cámara', 'centra el brazo'],
    description: 'Vuelve el brazo al centro (igual que el botón "Centrar" de los sliders).',
  ),
  VoiceCommandDoc(
    category: 'LEDs',
    examples: ['enciende el led 2', 'apaga el led 3'],
    description: 'Enciende/apaga un LED puntual (1 al 4).',
  ),
  VoiceCommandDoc(
    category: 'LEDs',
    examples: ['enciende el led 1 y el led 3'],
    description: 'Puedes combinar varios LEDs en una sola frase.',
  ),
  VoiceCommandDoc(
    category: 'LEDs',
    examples: ['enciende las luces', 'apaga todos los leds'],
    description: 'Enciende/apaga los 4 LEDs a la vez.',
  ),
  VoiceCommandDoc(
    category: 'LEDs',
    examples: ['luz roja', 'luz azul', 'luz verde'],
    description: 'Alias de LED 1/2/3 — los LEDs son on/off simples, no cambian de color de verdad.',
  ),
  VoiceCommandDoc(
    category: 'Foto',
    examples: ['toma una foto', 'saca una foto', 'captura una imagen'],
    description: 'Toma una foto real con la ESP32-CAM y la guarda en la Galería de la app.',
  ),
  VoiceCommandDoc(
    category: 'Preguntas a la IA',
    examples: ['¿qué estás viendo?', '¿hay algo frente al carrito?'],
    description:
        'Cualquier frase que no sea un comando de la lista se manda a Gemini junto con una foto '
        'actual de la cámara. La respuesta se muestra en pantalla y se lee en voz alta. '
        'Requiere API Key configurada e Internet.',
  ),
];
