import 'dart:typed_data';

/// Escritor de video Motion-JPEG en contenedor AVI: cada frame es un JPEG
/// tal cual (ya con el filtro quemado, ver `frame_filter.dart`), sin
/// re-codificar a H.264. Se eligió así porque el libmpv que trae el APK
/// (media_kit_libs_android_video) viene compilado sin muxers ni encoders
/// de video — no puede escribir ningún archivo de video por sí mismo — pero
/// sí trae el demuxer AVI y el decoder MJPEG, así que la propia app
/// reproduce lo que graba. VLC y cualquier PC también lo abren.
abstract class AviWriter {
  String get path;
  int get frameCount;
  int get bytesWritten;

  /// Agrega un frame. El tamaño del video lo fija el primer frame; los
  /// siguientes deben tener el mismo.
  Future<void> addFrame(Uint8List jpeg, int width, int height);

  /// Cierra el archivo escribiendo el índice y los encabezados finales
  /// (cantidad de frames y fps reales = frames / [durationMs]).
  Future<void> close(int durationMs);
}
