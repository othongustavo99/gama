import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Salva texto ou imagens geradas no dispositivo (Android / Windows).
class DownloadService {
  DownloadService._();
  static final DownloadService instance = DownloadService._();

  Future<Directory> _targetDir() async {
    if (!kIsWeb && Platform.isAndroid) {
      // Preferência: pasta Downloads do app (acessível); fallback app docs
      try {
        final ext = await getExternalStorageDirectory();
        if (ext != null) {
          final dl = Directory(p.join(ext.path, 'Download', 'Gamma'));
          if (!await dl.exists()) await dl.create(recursive: true);
          return dl;
        }
      } catch (_) {}
    }
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'GammaDownloads'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  String _stamp() {
    final n = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${n.year}${two(n.month)}${two(n.day)}_${two(n.hour)}${two(n.minute)}${two(n.second)}';
  }

  Future<String> saveText(String text, {String? filename}) async {
    final dir = await _targetDir();
    final name = filename ?? 'gamma_${_stamp()}.md';
    final file = File(p.join(dir.path, name));
    await file.writeAsString(text, encoding: utf8);
    return file.path;
  }

  Future<String> saveBase64Image(
    String base64Data, {
    String mime = 'image/png',
    String? filename,
  }) async {
    final dir = await _targetDir();
    var ext = 'png';
    if (mime.contains('jpeg') || mime.contains('jpg')) ext = 'jpg';
    if (mime.contains('webp')) ext = 'webp';
    if (mime.contains('gif')) ext = 'gif';
    final name = filename ?? 'gamma_img_${_stamp()}.$ext';
    final bytes = base64Decode(base64Data.replaceAll(RegExp(r'\s'), ''));
    final file = File(p.join(dir.path, name));
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  Future<void> openPath(String path) async {
    try {
      await OpenFilex.open(path);
    } catch (_) {}
  }

  Future<void> copyText(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
  }
}
