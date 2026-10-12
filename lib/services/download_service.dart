import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:dio/dio.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/constants.dart';
import 'auth_service.dart';
import 'identity_service.dart';
import 'settings_service.dart';

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

  Future<String> downloadArtifact(
    String downloadPath, {
    required String filename,
  }) async {
    if (!downloadPath.startsWith('/artifacts/')) {
      throw ArgumentError.value(downloadPath, 'downloadPath', 'caminho inválido');
    }
    final safeName = p.basename(filename).replaceAll(RegExp(r'[\\/\x00-\x1F]'), '_');
    final token = await AuthService.instance.bearerToken();
    final dio = Dio(
      BaseOptions(
        baseUrl: SettingsService.instance.baseUrl,
        connectTimeout: const Duration(seconds: 20),
        receiveTimeout: const Duration(minutes: 2),
        headers: {
          ...AppConstants.authHeaders,
          'X-User-Id': IdentityService.instance.userId,
          if (token != null) 'Authorization': 'Bearer $token',
        },
      ),
    );
    final dir = await _targetDir();
    final file = File(p.join(dir.path, safeName));
    final partial = File(
      '${file.path}.part-${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      final response = await dio.download(
        downloadPath,
        partial.path,
        deleteOnError: true,
      );
      if (response.statusCode != 200 ||
          !await partial.exists() ||
          await partial.length() == 0) {
        throw Exception('O servidor não retornou o arquivo completo.');
      }
      if (await file.exists()) await file.delete();
      await partial.rename(file.path);
    } catch (_) {
      if (await partial.exists()) await partial.delete();
      rethrow;
    }
    return file.path;
  }

  Future<void> openPath(String path) async {
    try {
      await OpenFilex.open(path);
    } catch (_) {}
  }

  /// Opens a generated file through the platform's file-opening flow.
  /// Android shows the system "Open with" chooser; Windows opens Explorer
  /// with the file selected. Other platforms use their default file handler.
  Future<void> openGeneratedFile(String path) async {
    if (kIsWeb) {
      await OpenFilex.open(path);
      return;
    }

    if (Platform.isAndroid) {
      await const MethodChannel('com.example.gama/file_opener')
          .invokeMethod<void>('openWithChooser', {'path': path});
      return;
    }

    if (Platform.isWindows) {
      final file = File(path);
      if (!await file.exists()) {
        throw FileSystemException('Arquivo não encontrado', path);
      }
      await Process.start(
        'explorer.exe',
        ['/select,', p.normalize(file.absolute.path)],
        mode: ProcessStartMode.detached,
      );
      return;
    }

    final result = await OpenFilex.open(path);
    if (result.type != ResultType.done) {
      throw Exception(
        result.message.isNotEmpty
            ? result.message
            : 'Não foi possível abrir o arquivo.',
      );
    }
  }

  Future<void> copyText(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
  }
}
