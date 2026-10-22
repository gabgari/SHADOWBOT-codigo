// Escucha del anuncio UDP de la PC de visión. En Web no hay sockets UDP:
// ahí se usa el stub (solo IP manual).
export 'vision_discovery_stub.dart' if (dart.library.io) 'vision_discovery_io.dart';
