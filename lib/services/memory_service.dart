import 'package:dio/dio.dart';

import 'identity_service.dart';
import 'settings_service.dart';

class MemoryFact {
  final String id;
  final String text;
  final String createdAt;
  final String source;

  MemoryFact({
    required this.id,
    required this.text,
    required this.createdAt,
    required this.source,
  });

  factory MemoryFact.fromJson(Map<String, dynamic> json) {
    return MemoryFact(
      id: json['id']?.toString() ?? '',
      text: json['text']?.toString() ?? '',
      createdAt: json['created_at']?.toString() ?? '',
      source: json['source']?.toString() ?? 'user',
    );
  }
}

class MemoryService {
  final Dio _client = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 20),
    ),
  );

  Dio _dio() {
    _client.options.baseUrl = SettingsService.instance.baseUrl;
    _client.options.headers['X-User-Id'] = IdentityService.instance.userId;
    return _client;
  }

  /// Após login Google: mescla memória de ids legados (google_<numeric>)
  /// na chave estável google_email_*.
  Future<void> migrateIfNeeded() async {
    final from = IdentityService.instance.takeMigrateFrom();
    if (from == null || from.isEmpty) return;
    final to = IdentityService.instance.userId;
    if (from == to) return;
    try {
      await _dio().post(
        '/memory/migrate',
        data: {'from_user_id': from, 'to_user_id': to},
        options: Options(
          headers: {'X-User-Id': to},
        ),
      );
    } catch (_) {
      // silencioso: não bloqueia o app se o endpoint ainda não existir
    }
    // tenta também o id numérico gravado
    final numeric = IdentityService.instance.googleNumericId;
    if (numeric != null && numeric.isNotEmpty) {
      final alt = 'google_$numeric';
      if (alt != to && alt != from) {
        try {
          await _dio().post(
            '/memory/migrate',
            data: {'from_user_id': alt, 'to_user_id': to},
            options: Options(headers: {'X-User-Id': to}),
          );
        } catch (_) {}
      }
    }
  }

  Future<List<MemoryFact>> listFacts() async {
    final res = await _dio().get('/memory');
    final data = res.data as Map<String, dynamic>;
    final list = data['facts'] as List<dynamic>? ?? [];
    return list
        .map((e) => MemoryFact.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  Future<MemoryFact> addFact(String text) async {
    final res = await _dio().post('/memory', data: {'text': text});
    final data = res.data as Map<String, dynamic>;
    return MemoryFact.fromJson(Map<String, dynamic>.from(data['fact'] as Map));
  }

  Future<void> deleteFact(String id) async {
    await _dio().delete('/memory/$id');
  }

  Future<void> clear() async {
    await _dio().delete('/memory');
  }
}
