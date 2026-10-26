import 'package:dio/dio.dart';

import '../core/constants.dart';
import 'auth_interceptor.dart';
import 'settings_service.dart';

/// Consulta as tarefas de conversa e entregas persistidas no servidor.
/// Não inicia nenhuma chamada paga de IA.
class RecoveryService {
  RecoveryService._();
  static final instance = RecoveryService._();

  Dio _client() {
    final dio = Dio(BaseOptions(
      baseUrl: SettingsService.instance.baseUrl,
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 25),
      headers: AppConstants.authHeaders,
    ));
    dio.interceptors.add(GammaAuthInterceptor(client: dio));
    return dio;
  }

  List<Map<String, dynamic>> _items(dynamic data, String field) {
    final map = data is Map ? data : const {};
    final raw = map[field];
    if (raw is! List) return const [];
    return raw.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
  }

  Future<List<Map<String, dynamic>>> jobs() async {
    final response = await _client().get('/jobs');
    return _items(response.data, 'jobs');
  }

  Future<List<Map<String, dynamic>>> artifacts() async {
    final response = await _client().get('/artifacts');
    return _items(response.data, 'artifacts');
  }
}
