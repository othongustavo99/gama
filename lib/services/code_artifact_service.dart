import 'package:dio/dio.dart';

import '../core/constants.dart';
import '../models/code_artifact.dart';
import 'auth_interceptor.dart';
import 'download_service.dart';
import 'identity_service.dart';
import 'settings_service.dart';

class CodeArtifactService {
  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 12),
      receiveTimeout: const Duration(seconds: 30),
    ),
  );

  CodeArtifactService() {
    _dio.interceptors.add(GammaAuthInterceptor(client: _dio));
  }

  Dio _client() {
    _dio.options.baseUrl = SettingsService.instance.baseUrl;
    _dio.options.headers['X-User-Id'] = IdentityService.instance.userId;
    _dio.options.headers.addAll(AppConstants.authHeaders);
    return _dio;
  }

  Future<List<CodeArtifactFile>> listFiles(CodeArchive archive) async {
    final response = await _client().get<Map<String, dynamic>>(
      '/artifacts/${archive.id}/files',
    );
    final files = response.data?['files'];
    if (files is! List)
      throw const FormatException('Índice de arquivos inválido.');
    return [
      for (final file in files.whereType<Map>())
        if (file['index'] is int &&
            file['name'] is String &&
            file['size'] is int)
          CodeArtifactFile(
            name: file['name'] as String,
            language: (file['name'] as String).split('.').last,
            archiveIndex: file['index'] as int,
            size: file['size'] as int,
          ),
    ];
  }

  Future<({String? text, String? reason, String? diff})> preview(
    CodeArchive archive,
    CodeArtifactFile file,
  ) async {
    final response = await _client().get<Map<String, dynamic>>(
      '/artifacts/${archive.id}/files/${file.archiveIndex!}',
    );
    final data = response.data;
    if (data == null || (!data.containsKey('content'))) {
      throw const FormatException('Prévia do arquivo inválida.');
    }
    return (
      text: data['content'] as String?,
      reason: data['reason'] as String?,
      diff: data['diff'] as String?,
    );
  }

  Future<void> download(CodeArchive archive, CodeArtifactFile file) async {
    final response = await _client().get<ResponseBody>(
      '/artifacts/${archive.id}/files/${file.archiveIndex!}/download',
      options: Options(responseType: ResponseType.stream),
    );
    final stream = response.data?.stream;
    if (stream == null)
      throw const FormatException('O servidor não enviou o arquivo.');
    await DownloadService.instance.saveStream(
      stream,
      filename: file.name,
      size: file.size,
    );
  }

  void dispose() => _dio.close(force: true);
}
