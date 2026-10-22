/// Bailes con canción: la app pone el audio en la bocina del celular y la
/// ESP32-S3 de control mueve motores + brazo al ritmo (`/baile?n=`).
///
/// Los audios van en `app/assets/audio/` (copias recortadas de
/// `firmware/EVERYBODY DANCE.mp3` y `firmware/TOKIODRIFT DANCE.mp3`). La app
/// salta a [startSec] y corta a los [durSec] segundos.
/// Si el archivo no está, el carrito baila igual, sin música.
class DanceSong {
  final int n; // número de baile en la ESP32 (ver DANCES en CONTROL.ino)
  final String title;
  final String artist;
  final String asset; // ruta dentro de assets/
  final double startSec; // desde dónde suena la canción
  final double durSec; // cuánto dura el baile (igual que la coreografía)
  final String padKey; // flecha del mando que lo lanza en modo DANCE

  const DanceSong({
    required this.n,
    required this.title,
    required this.artist,
    required this.asset,
    required this.startSec,
    required this.durSec,
    required this.padKey,
  });

  String get rangeLabel {
    String f(double s) => '${s ~/ 60}:${(s % 60).round().toString().padLeft(2, '0')}';
    return '${f(startSec)} – ${f(startSec + durSec)}';
  }
}

const danceSongs = <DanceSong>[
  DanceSong(
    n: 5,
    title: 'Everybody',
    artist: 'Backstreet Boys',
    asset: 'assets/audio/everybody.mp3',
    startSec: 0, // el archivo ya viene recortado al coro
    durSec: 21.5,
    padKey: '←',
  ),
  DanceSong(
    n: 6,
    title: 'Tokyo Drift',
    artist: 'Teriyaki Boyz',
    asset: 'assets/audio/tokyo_drift.mp3',
    startSec: 0,
    durSec: 13.6, // hasta "Fast and Furious"
    padKey: '→',
  ),
];
