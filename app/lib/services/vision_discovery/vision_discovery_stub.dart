/// Sin sockets UDP (Web): no hay descubrimiento, solo las IPs manuales.
class VisionDiscovery {
  VisionDiscovery({required void Function(String url) onFound, int port = 5001});

  bool get listening => false;
  Future<void> start() async {}
  Future<void> stop() async {}
}

class BoardDiscovery {
  BoardDiscovery({required void Function(String board, String ip, String? controlIp) onFound, int port = 4210});

  bool get listening => false;
  Future<void> start() async {}
  Future<void> stop() async {}
}
