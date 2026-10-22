import 'dart:typed_data';

import 'package:flutter/painting.dart';

import 'avi_writer.dart';

/// Respaldo para plataformas sin `dart:io` ni `dart:html`: nada se guarda.
const bool mediaFilesPersistent = false;

Future<String?> writeMediaBytes(String filename, Uint8List bytes) async => null;
Future<String?> readMediaIndex() async => null;
Future<void> writeMediaIndex(String json) async {}
Future<bool> mediaFileExists(String path) async => false;
Future<void> deleteMediaFile(String path) async {}
Future<int> mediaFileSize(String path) async => 0;
Future<AviWriter?> openAviWriter(String filename) async => null;
ImageProvider? mediaImageProvider(String path) => null;
