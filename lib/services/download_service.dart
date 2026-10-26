import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:dio/dio.dart';
import 'package:crypto/crypto.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/constants.dart';
import 'auth_service.dart';
import 'auth_interceptor.dart';
import 'identity_service.dart';
import 'settings_service.dart';
import '../utils/error_logger.dart';

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
          final dl = Directory(p.join(ext.path, 'Download', 'Gama'));
          if (!await dl.exists()) await dl.create(recursive: true);
          return dl;
        }
      } catch (error, stack) {
        logSwallowed(error, stack);
      }
    }
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'GamaDownloads'));
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

  Future<String> copyFile(String sourcePath, {String? filename}) async {
    final source = File(sourcePath);
    if (!await source.exists()) {
      throw const FileSystemException('Arquivo de origem não encontrado');
    }
    final dir = await _targetDir();
    final base = filename ?? p.basename(sourcePath);
    final safeName = base.replaceAll(RegExp(r'[\\/\x00-\x1F]'), '_');
    final destination = File(p.join(dir.path, safeName));
    await source.copy(destination.path);
    return destination.path;
  }

  /// Exporta o arquivo para Downloads/Gama (coleção pública do Android 10+).
  /// Mantém a cópia privada usada pelo player e pela Biblioteca intacta.
  Future<void> exportToDownloads(String sourcePath, {String? filename}) async {
    final source = File(sourcePath);
    if (!await source.exists() || await source.length() <= 0) {
      throw const FileSystemException('Arquivo vazio ou não encontrado');
    }
    if (!kIsWeb && Platform.isAndroid) {
      await const MethodChannel('com.example.gama/file_opener').invokeMethod<String>(
        'saveToDownloads',
        {'path': sourcePath, 'filename': filename ?? p.basename(sourcePath)},
      );
      return;
    }
    await copyFile(sourcePath, filename: filename);
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
    String? expectedSha256,
    int? expectedSize,
  }) async {
    if (!downloadPath.startsWith('/artifacts/')) {
      throw ArgumentError.value(
        downloadPath,
        'downloadPath',
        'caminho inválido',
      );
    }
    final safeName = p
        .basename(filename)
        .replaceAll(RegExp(r'[\\/\x00-\x1F]'), '_');
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
    if (!dio.interceptors.any((i) => i is GammaAuthInterceptor)) {
      dio.interceptors.add(GammaAuthInterceptor(client: dio));
    }
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
      final fileSize = await partial.length();
      if (expectedSize != null && expectedSize > 0 &&
          fileSize != expectedSize) {
        throw const FormatException('O download não tem o tamanho esperado.');
      }
      if (safeName.toLowerCase().endsWith('.zip')) {
        // Header and central directory/EOCD are checked without inflating the
        // ZIP on a memory-constrained phone. Full CRC was checked by backend.
        await _checkZipContainer(partial);
      }
      if (expectedSha256 != null &&
          RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(expectedSha256)) {
        final actual = (await sha256.bind(partial.openRead()).first).toString();
        if (actual.toLowerCase() != expectedSha256.toLowerCase()) {
          throw const FormatException('A verificação SHA-256 do arquivo falhou.');
        }
      }
      if (await file.exists()) await file.delete();
      await partial.rename(file.path);
    } on DioException catch (e) {
      if (await partial.exists()) await partial.delete();
      // Mostra a mensagem real da API (por exemplo, identidade inválida),
      // em vez de deixar o usuário apenas com o status HTTP 400.
      final body = e.response?.data;
      String detail = '';
      if (body is Map) {
        detail = (body['detail'] ?? body['message'] ?? '').toString();
      } else if (body is String) {
        detail = body.trim();
      }
      if (detail.isNotEmpty) {
        throw Exception(
          'Falha ao baixar arquivo (HTTP ${e.response?.statusCode}): $detail',
        );
      }
      rethrow;
    } catch (error, stack) {
      logSwallowed(error, stack);
      if (await partial.exists()) await partial.delete();
      rethrow;
    }
    return file.path;
  }

  /// Reject a truncated or non-ZIP HTTP response without reading all files
  /// into RAM. A SHA-256 from the backend gives a stronger verification.
  Future<void> _checkZipContainer(File file) async {
    final handle = await file.open();
    try {
      final length = await handle.length();
      if (length < 22) {
        throw const FormatException('ZIP vazio ou incompleto.');
      }
      await handle.setPosition(0);
      final header = await handle.read(4);
      if (header.length != 4 || header[0] != 0x50 || header[1] != 0x4b ||
          header[2] != 0x03 || header[3] != 0x04) {
        throw const FormatException('Assinatura do ZIP inválida.');
      }
      // EOCD can be followed by a ZIP comment up to 65,535 bytes.
      final tailSize = length < 65557 ? length : 65557;
      await handle.setPosition(length - tailSize);
      final tail = await handle.read(tailSize);
      var found = false;
      for (var i = tail.length - 22; i >= 0; i--) {
        if (tail[i] != 0x50 || tail[i + 1] != 0x4b ||
            tail[i + 2] != 0x05 || tail[i + 3] != 0x06) {
          continue;
        }
        final commentLength = tail[i + 20] | (tail[i + 21] << 8);
        if (i + 22 + commentLength == tail.length) {
          found = true;
          break;
        }
      }
      if (!found) {
        throw const FormatException('ZIP truncado: índice final ausente.');
      }
    } finally {
      await handle.close();
    }
  }

  Future<void> openPath(String path) async {
    try {
      await OpenFilex.open(path);
    } catch (error, stack) {
      logSwallowed(error, stack);
    }
  }

  /// Opens a generated file through the platform's file-opening flow.
  /// Android shows the system "Open with" chooser; desktop opens the file
  /// with its default application.
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
      final result = await OpenFilex.open(p.normalize(file.absolute.path));
      if (result.type != ResultType.done) {
        throw FileSystemException(
          result.message.isEmpty
              ? 'Não foi possível abrir o arquivo'
              : result.message,
          path,
        );
      }
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
