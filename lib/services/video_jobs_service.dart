import 'package:dio/dio.dart';

import '../core/constants.dart';
import 'auth_interceptor.dart';
import 'settings_service.dart';

/// Consulta e recupera um vídeo já submetido. Nunca cria novo job pago.
class VideoJobsService {
  VideoJobsService._();
  static final instance = VideoJobsService._();

  Dio _client() {
    final dio = Dio(BaseOptions(
      baseUrl: SettingsService.instance.baseUrl,
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 90),
      headers: AppConstants.authHeaders,
    ));
    dio.interceptors.add(GammaAuthInterceptor(client: dio));
    return dio;
  }

  Map<String, dynamic> _asMap(dynamic raw) =>
      raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};

  Future<List<Map<String, dynamic>>> list() async {
    final response = await _client().get('/media/video-jobs');
    final json = _asMap(response.data);
    final items = json['jobs'];
    if (items is! List) return const [];
    return items.whereType<Map>().map((job) => Map<String, dynamic>.from(job)).toList();
  }

  Future<Map<String, dynamic>> resume(String jobId) async {
    if (!RegExp(r'^[a-f0-9]{16}$').hasMatch(jobId)) {
      throw ArgumentError('Trabalho inválido');
    }
    final response = await _client().post('/media/video-jobs/$jobId/resume');
    return _asMap(_asMap(response.data)['job']);
  }
}
