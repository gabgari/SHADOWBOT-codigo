// Búsqueda de equipos en la red local por puerto (p. ej. la Tapo por RTSP
// 554). En Web no hay sockets: ahí no busca nada.
export 'lan_scan_stub.dart' if (dart.library.io) 'lan_scan_io.dart';
