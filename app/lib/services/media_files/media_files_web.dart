import 'dart:typed_data';

import 'package:flutter/painting.dart';
// ignore: deprecated_member_use, avoid_web_libraries_in_flutter
import 'dart:html' as html;

import 'avi_writer.dart';

/// Web no tiene sistema de archivos: las fotos se descargan con el
/// navegador (carpeta "Descargas") y Multimedia solo las muestra mientras
/// la pestaña siga abierta. Grabar video no está disponible aquí.
const bool mediaFilesPersistent = false;

Future<String?> writeMediaBytes(String filename, Uint8List bytes) async {
  final blob = html.Blob([bytes], filename.endsWith('.jpg') ? 'image/jpeg' : 'application/octet-stream');
  final url = html.Url.createObjectUrlFromBlob(blob);
  html.AnchorElement(href: url)
    ..download = filename
    ..style.display = 'none'
    ..click();
  html.Url.revokeObjectUrl(url);
  return 'Descargas del navegador ($filename)';
}

Future<String?> readMediaIndex() async => null;
Future<void> writeMediaIndex(String json) async {}
Future<bool> mediaFileExists(String path) async => false;
Future<void> deleteMediaFile(String path) async {}
Future<int> mediaFileSize(String path) async => 0;
Future<AviWriter?> openAviWriter(String filename) async => null;
ImageProvider? mediaImageProvider(String path) => null;
