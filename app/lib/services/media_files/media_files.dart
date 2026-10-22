/// Archivos de la sección Multimedia (fotos, videos y su índice).
///
/// La implementación real se elige en tiempo de compilación según la
/// plataforma: `media_files_io.dart` (móvil/escritorio: carpeta
/// `ShadowBot/` vía `path_provider` + `dart:io`) o `media_files_web.dart`
/// (Web: sin sistema de archivos — las fotos se descargan con el navegador
/// y no se pueden grabar videos). `media_files_stub.dart` es el respaldo si
/// ninguna aplica.
library;

export 'avi_writer.dart';
export 'media_files_stub.dart'
    if (dart.library.io) 'media_files_io.dart'
    if (dart.library.html) 'media_files_web.dart';
