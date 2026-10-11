import 'package:dio/dio.dart';

import '../core/constants.dart';
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
    _client.options.headers.addAll(AppConstants.authHeaders);
    return _client;
  }

  /// Após login Google: mescla memória de ids legados (google_<numeric>)
  /// na chave estável google_email_*.
  /// Tenta todas as origens conhecidas e não falha o app se o endpoint
  /// ainda não existir ou a rede cair.
  Future<void> migrateIfNeeded() async {
    final to = IdentityService.instance.userId;
    if (to.isEmpty || to == 'default') return;

    final candidates = <String>{};

    final from = IdentityService.instance.takeMigrateFrom();
    if (from != null && from.isNotEmpty && from != to) {
      candidates.add(from);
    }

    final numeric = IdentityService.instance.googleNumericId;
    if (numeric != null && numeric.isNotEmpty) {
      final alt = 'google_$numeric';
      if (alt != to) candidates.add(alt);
    }

    // Também tenta id legado que possa estar ainda no prefs (sem consumir)
    // — IdentityService.takeMigrateFrom já limpa as chaves principais.

    for (final src in candidates) {
      try {
        final res = await _dio().post(
          '/memory/migrate',
          data: {'from_user_id': src, 'to_user_id': to},
          options: Options(
            headers: {'X-User-Id': to},
            validateStatus: (s) => s != null && s < 500,
          ),
        );
        // 404 = endpoint antigo sem migrate; 403 = política; 200 = ok
        if (res.statusCode == 200) {
          // sucesso — continua tentando outras origens se houver
        }
      } catch (_) {
        // silencioso: não bloqueia o app
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
