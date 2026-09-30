import 'package:dio/dio.dart';

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
  Dio _dio() {
    return Dio(
      BaseOptions(
        baseUrl: SettingsService.instance.baseUrl,
        connectTimeout: const Duration(seconds: 8),
        receiveTimeout: const Duration(seconds: 15),
      ),
    );
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
    return MemoryFact.fromJson(
      Map<String, dynamic>.from(data['fact'] as Map),
    );
  }

  Future<void> deleteFact(String id) async {
    await _dio().delete('/memory/$id');
  }

  Future<void> clear() async {
    await _dio().delete('/memory');
  }
}
