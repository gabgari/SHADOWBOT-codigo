/// Vibración del mando al ritmo de los bailes.
///
/// Copia los TIEMPOS de las coreografías de CONTROL.ino (BAILE_GIRO,
/// BAILE_ZIGZAG, …): cada paso dura lo mismo que allá y vibra con una
/// fuerza según qué tan fuerte van los motores en ese paso. Si se cambia
/// una coreografía en el firmware, hay que cambiar aquí sus duraciones.
///
/// La app sabe en qué milisegundo va el baile por /estado (`t`), así que
/// el mando golpea justo cuando el carrito cambia de paso.
class RumbleStep {
  final int ms; // duración del paso (igual que en el firmware)
  final int amp; // fuerza 0-255 (0 = paso quieto, sin vibrar)
  const RumbleStep(this.ms, this.amp);
}

class DanceRumble {
  final List<RumbleStep> steps;

  /// Golpes extra dentro de los pasos largos (ms entre golpes; 0 = sin).
  final int beatMs;
  const DanceRumble(this.steps, {this.beatMs = 0});

  /// Paso y golpe en que va el baile a los [elapsedMs] del arranque de los
  /// motores, o `null` si ya terminó. `sub` = golpe dentro del paso.
  ({int step, int sub, RumbleStep s})? at(int elapsedMs) {
    if (elapsedMs < 0) return null;
    var t = 0;
    for (var i = 0; i < steps.length; i++) {
      final s = steps[i];
      if (elapsedMs < t + s.ms) {
        final inside = elapsedMs - t;
        final sub = beatMs > 0 && s.ms >= 2 * beatMs - 50 ? inside ~/ beatMs : 0;
        return (step: i, sub: sub, s: s);
      }
      t += s.ms;
    }
    return null;
  }
}

// Fuerzas: motores a ~190 → 190; solo el brazo moviéndose → 90 (toque suave).
const _arm = 90;
const _be = 556; // un tiempo de "Everybody" (108 BPM)

List<RumbleStep> _rep(int n, List<RumbleStep> s) => [for (var i = 0; i < n; i++) ...s];

final danceRumbles = <int, DanceRumble>{
  // 1 ✕ GIRO LOCO
  1: DanceRumble([..._rep(4, const [RumbleStep(600, 190)]), const RumbleStep(200, 0)]),
  // 2 ○ ZIGZAG
  2: DanceRumble([..._rep(6, const [RumbleStep(350, 120)]), const RumbleStep(700, 190), const RumbleStep(200, 0)]),
  // 3 □ SÍ Y NO
  3: DanceRumble([
    ..._rep(4, const [RumbleStep(250, _arm)]),
    const RumbleStep(150, _arm),
    ..._rep(4, const [RumbleStep(200, 120)]),
    const RumbleStep(200, 0),
  ]),
  // 4 △ TWIST
  4: DanceRumble([..._rep(4, const [RumbleStep(200, 190)]), ..._rep(2, const [RumbleStep(400, 190)]), const RumbleStep(200, 0)]),
  // 5 EVERYBODY (un golpe por tiempo, también en los pasos largos)
  5: DanceRumble([
    ..._rep(8, const [RumbleStep(_be, 120)]),
    ..._rep(8, const [RumbleStep(_be, 170)]),
    ..._rep(2, const [RumbleStep(2 * _be, 190)]),
    ..._rep(4, const [RumbleStep(_be, _arm)]),
    ..._rep(8, const [RumbleStep(_be, 140)]),
    const RumbleStep(4 * _be, 220),
    ..._rep(3, const [RumbleStep(_be, _arm)]),
  ], beatMs: _be),
  // 6 TOKYO DRIFT (donas largas: golpe cada ~460 ms ≈ 130 BPM)
  6: DanceRumble(const [
    RumbleStep(600, 100),
    RumbleStep(600, 160),
    RumbleStep(600, 220),
    RumbleStep(3200, 160),
    RumbleStep(2000, 240),
    RumbleStep(3200, 160),
    RumbleStep(1900, 255),
    RumbleStep(700, _arm),
    RumbleStep(800, _arm),
  ], beatMs: 462),
};
