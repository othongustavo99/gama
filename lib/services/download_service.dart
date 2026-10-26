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
import 'local_account_scope.dart';
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
          final dl = Directory(p.join(ext.path, 'Download', 'Gama', LocalAccountScope.current().internalDownloadsDirectoryName));
          if (!await dl.exists()) await dl.create(recursive: true);
          return dl;
        }
      } catch (error, stack) {
        logSwallowed(error, stack);
      }
    }
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, LocalAccountScope.current().internalDownloadsDirectoryName));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  String _stamp() {
    final n = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${n.year}${two(n.month)}${two(n.day)}_${two(n.hour)}${two(n.minute)}${two(n.second)}';
  }

  String _safeFilename(String value) {
    final name = p.basename(value.replaceAll('\\', '/'))
        .replaceAll(RegExp(r'[\\/\x00-\x1F\x7F]'), '_').trim();
    if (name.isEmpty || name == '.' || name == '..') {
      throw const FormatException('Nome de arquivo inválido.');
    }
    return name;
  }

  /// Nunca sobrescreve silenciosamente um download anterior com o mesmo nome.
  Future<File> _availableFile(Directory dir, String filename) async {
    final safe = _safeFilename(filename);
    final ext = p.extension(safe);
    final stem = p.basenameWithoutExtension(safe);
    var candidate = File(p.join(dir.path, safe));
    for (var number = 2; await candidate.exists(); number++) {
      candidate = File(p.join(dir.path, '$stem ($number)$ext'));
    }
    return candidate;
  }

  Future<String> saveText(String text, {String? filename}) async {
    final dir = await _targetDir();
    final name = filename ?? 'gamma_${_stamp()}.md';
    final file = await _availableFile(dir, name);
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
    final destination = await _availableFile(dir, base);
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
    final file = await _availableFile(dir, name);
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  Future<String> downloadArtifact(
    String downloadPath, {
    required String filename,
    String? expectedSha256,
    int? expectedSize,
  }) async {
    // Endereço vem de metadados do servidor ou do texto gerado pelo modelo.
    // Nunca faça download de caminhos arbitrários introduzidos em mensagens.
    final match = RegExp(r'^/artifacts/([a-f0-9]{16})/download$')
        .firstMatch(downloadPath);
    if (match == null) {
      throw const FormatException('Link de arquivo inválido.');
    }
    final artifactId = match.group(1)!;
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
    dio.interceptors.add(GammaAuthInterceptor(client: dio));

    // O próprio servidor autenticado fornece o tamanho e SHA-256 oficiais.
    // Não dependa exclusivamente de valores vindos de uma mensagem da IA.
    final metadataResponse = await dio.get<Map<String, dynamic>>(
      '/artifacts/$artifactId',
    );
    final metadata = metadataResponse.data;
    if (metadata == null || metadata['artifact_id']?.toString() != artifactId) {
      throw const FormatException('Metadados do arquivo inválidos.');
    }
    final serverHash = metadata['sha256']?.toString().toLowerCase() ?? '';
    final serverSize = int.tryParse(metadata['size']?.toString() ?? '');
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(serverHash) ||
        serverSize == null || serverSize <= 0) {
      throw const FormatException('O servidor não forneceu dados válidos de integridade.');
    }
    if (expectedSha256 != null &&
        expectedSha256.isNotEmpty &&
        expectedSha256.toLowerCase() != serverHash) {
      throw const FormatException('Checksum da mensagem difere do arquivo armazenado.');
    }
    if (expectedSize != null && expectedSize > 0 &&
        expectedSize != serverSize) {
      throw const FormatException('Tamanho da mensagem difere do arquivo armazenado.');
    }

    final dir = await _targetDir();
    final safeName = _safeFilename(filename);
    final serverName = _safeFilename(metadata['filename']?.toString() ?? '');
    // Não deixe a extensão da mensagem decidir como abrir bytes diferentes.
    if (p.extension(safeName).toLowerCase() !=
        p.extension(serverName).toLowerCase()) {
      throw const FormatException('O tipo do arquivo não coincide com o servidor.');
    }
    final destination = await _availableFile(dir, safeName);
    final partial = File(
      '${destination.path}.part-${DateTime.now().microsecondsSinceEpoch}',
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
        throw const FormatException('O servidor não retornou o arquivo completo.');
      }
      if (await partial.length() != serverSize) {
        throw const FormatException('O download não tem o tamanho esperado.');
      }
      if (safeName.toLowerCase().endsWith('.zip')) {
        await _checkZipContainer(partial);
      }
      final actual = (await sha256.bind(partial.openRead()).first).toString();
      if (actual.toLowerCase() != serverHash) {
        throw const FormatException('A verificação SHA-256 do arquivo falhou.');
      }
      // Só torna visível depois de validar bytes, tamanho, extensão e hash.
      // Nunca apaga uma versão previamente baixada com o mesmo nome.
      if (await destination.exists()) {
        throw const FileSystemException('O nome do download já está em uso.');
      }
      await partial.rename(destination.path);
      return destination.path;
    } on DioException catch (error) {
      if (await partial.exists()) await partial.delete();
      final body = error.response?.data;
      String detail = '';
      if (body is Map) {
        detail = (body['detail'] ?? body['message'] ?? '').toString();
      } else if (body is String) {
        detail = body.trim();
      }
      if (detail.isNotEmpty) {
        throw Exception(
          'Falha ao baixar arquivo (HTTP ${error.response?.statusCode}): $detail',
        );
      }
      rethrow;
    } catch (error, stack) {
      logSwallowed(error, stack);
      if (await partial.exists()) await partial.delete();
      rethrow;
    }
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
