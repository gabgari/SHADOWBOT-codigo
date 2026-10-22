/// Sin sockets (Web): no se puede buscar en la red.
Future<List<String>> scanLanForPort(int port) async => const [];

/// Sin sockets (Web): no se puede comprobar.
Future<bool?> rtspCredentialsOk(Uri url) async => null;
