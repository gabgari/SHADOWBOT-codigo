import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../app_theme.dart';

/// Reproductor MJPEG mínimo para el endpoint `/stream` del ESP32-CAM
/// (`multipart/x-mixed-replace`, ver `startCameraServer()` en
/// `firmware/CAMARA/CAMARA.ino`).
///
/// En vez de depender de un paquete externo, decodifica el stream buscando
/// las marcas JPEG SOI (0xFFD8) y EOI (0xFFD9) directamente en los bytes
/// recibidos — es lo que necesita el formato que ya genera el firmware.
///
/// *** VINCULACIÓN PENDIENTE ***
/// Este widget solo se usa cuando el nodo ESP32-CAM está vinculado
/// (host configurado en Sistema > Conexiones). Mientras tanto,
/// `control_screen.dart` y `camara_screen.dart` muestran
/// `CorridorPlaceholder` en su lugar.
/// El ESP32-CAM queda montado de lado en el brazo pan/tilt, así que el
/// sensor entrega el video "acostado". 3 quarterTurns = 270° horario
/// (= 90° antihorario): el lado que antes era el de arriba de la imagen
/// queda apuntando a la izquierda. Si al probarlo queda al revés, cambia
/// esto a 1 (90° horario).
const int kCamRotationQuarterTurns = 3;

class MjpegView extends StatefulWidget {
  final Uri uri;

  /// Se llama con cada JPEG recibido (ver `Esp32CamService.pushFrame`).
  final ValueChanged<Uint8List>? onFrame;
  const MjpegView({super.key, required this.uri, this.onFrame});

  @override
  State<MjpegView> createState() => _MjpegViewState();
}

class _MjpegViewState extends State<MjpegView> {
  http.Client? _client;
  StreamSubscription<List<int>>? _sub;
  Uint8List? _frame;
  bool _errored = false;

  @override
  void initState() {
    super.initState();
    _connect();
  }

  @override
  void didUpdateWidget(covariant MjpegView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.uri != widget.uri) {
      _teardown();
      _connect();
    }
  }

  void _connect() {
    _errored = false;
    final client = http.Client();
    _client = client;
    final buffer = <int>[];

    client.send(http.Request('GET', widget.uri)).then((res) {
      _sub = res.stream.listen(
        (chunk) {
          buffer.addAll(chunk);
          _extractFrames(buffer);
        },
        onError: (_) => _markError(),
        onDone: () => _markError(),
        cancelOnError: true,
      );
    }).catchError((_) {
      _markError();
    });
  }

  void _extractFrames(List<int> buffer) {
    while (true) {
      final start = _indexOfMarker(buffer, 0xFF, 0xD8, 0);
      if (start == -1) {
        if (buffer.length > 2) buffer.removeRange(0, buffer.length - 2);
        return;
      }
      final end = _indexOfMarker(buffer, 0xFF, 0xD9, start + 2);
      if (end == -1) {
        if (start > 0) buffer.removeRange(0, start);
        return;
      }
      final frame = Uint8List.fromList(buffer.sublist(start, end + 2));
      buffer.removeRange(0, end + 2);
      widget.onFrame?.call(frame);
      if (mounted) {
        setState(() => _frame = frame);
      }
    }
  }

  int _indexOfMarker(List<int> buf, int a, int b, int from) {
    for (var i = from; i < buf.length - 1; i++) {
      if (buf[i] == a && buf[i + 1] == b) return i;
    }
    return -1;
  }

  void _markError() {
    if (mounted) setState(() => _errored = true);
  }

  void _teardown() {
    _sub?.cancel();
    _client?.close();
    _sub = null;
    _client = null;
  }

  @override
  void dispose() {
    _teardown();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_frame != null) {
      return RotatedBox(
        quarterTurns: kCamRotationQuarterTurns,
        child: Image.memory(
          _frame!,
          fit: BoxFit.cover,
          gaplessPlayback: true,
        ),
      );
    }
    return Container(
      color: AppColors.bg,
      alignment: Alignment.center,
      child: Text(
        _errored ? 'Sin señal de CAM 1' : 'Conectando al stream…',
        style: const TextStyle(color: AppColors.text2, fontSize: 12.5, fontWeight: FontWeight.w600),
      ),
    );
  }
}
