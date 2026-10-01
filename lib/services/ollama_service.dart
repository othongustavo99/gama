import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../models/message.dart';
import 'identity_service.dart';
import 'settings_service.dart';

class WebSource {
  final String title;
  final String url;
  final String snippet;

  const WebSource({required this.title, required this.url, this.snippet = ''});

  factory WebSource.fromJson(Map<String, dynamic> j) {
    return WebSource(
      title: (j['title'] ?? '').toString(),
      url: (j['url'] ?? j['href'] ?? '').toString(),
      snippet: (j['snippet'] ?? j['body'] ?? '').toString(),
    );
  }
}

class ChatStreamEvent {
  final String? token;
  final String? memorySaved;
  final String? phase; // searching | thinking | typing
  final String? webSearchQuery;
  final List<WebSource>? sources;

  const ChatStreamEvent._({
    this.token,
    this.memorySaved,
    this.phase,
    this.webSearchQuery,
    this.sources,
  });

  factory ChatStreamEvent.token(String t) => ChatStreamEvent._(token: t);

  factory ChatStreamEvent.memorySaved(String fact) =>
      ChatStreamEvent._(memorySaved: fact);

  factory ChatStreamEvent.meta({
    String? phase,
    String? webSearchQuery,
    List<WebSource>? sources,
    String? memorySaved,
  }) => ChatStreamEvent._(
    phase: phase,
    webSearchQuery: webSearchQuery,
    sources: sources,
    memorySaved: memorySaved,
  );
}

class OllamaService {
  Dio _createDio() {
    return Dio(
      BaseOptions(
        baseUrl: SettingsService.instance.baseUrl,
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(minutes: 5),
        sendTimeout: const Duration(seconds: 60),
      ),
    );
  }

  Future<List<String>> listModels() async {
    try {
      final dio = _createDio();
      final response = await dio.get('/models');
      final data = response.data as Map<String, dynamic>;
      final models = data['models'] as List<dynamic>? ?? [];
      return models
          .map((model) => model.toString())
          .where((model) => model.isNotEmpty)
          .toList();
    } on DioException catch (e) {
      throw Exception('Erro ao listar modelos: ${e.message}');
    } catch (e) {
      throw Exception('Erro ao processar lista de modelos: $e');
    }
  }

  Future<bool> ping() async {
    try {
      final dio = _createDio();
      final response = await dio.get(
        '/health',
        options: Options(
          receiveTimeout: const Duration(seconds: 5),
          sendTimeout: const Duration(seconds: 5),
        ),
      );
      if (response.statusCode != 200) return false;
      final data = response.data as Map<String, dynamic>;
      return data['ollama'] == 'online' ||
          data['llm'] == 'online' ||
          data['status'] == 'ok';
    } catch (_) {
      return false;
    }
  }

  Stream<ChatStreamEvent> chatStream({
    required List<Message> messages,
    String? model,
    List<Map<String, String>>? images,
  }) async* {
    final selectedModel = model ?? SettingsService.instance.model;
    final dio = _createDio();

    try {
      final requestMessages = messages
          .map((message) => message.toJson())
          .toList();

      final response = await dio.post(
        '/chat',
        data: {
          'model': selectedModel,
          'messages': requestMessages,
          if (images != null && images.isNotEmpty) 'images': images,
          'user_id': IdentityService.instance.userId,
          'auto_memory': true,
        },
        options: Options(
          responseType: ResponseType.stream,
          headers: {
            'Accept': 'application/x-ndjson',
            'X-User-Id': IdentityService.instance.userId,
          },
        ),
      );

      final body = response.data;
      if (body is! ResponseBody) {
        throw Exception('Resposta de stream inválida da API');
      }

      final lines = utf8.decoder.bind(body.stream);
      var buffer = '';

      await for (final chunk in lines) {
        buffer += chunk;
        final parts = buffer.split('\n');
        buffer = parts.removeLast();

        for (final line in parts) {
          final trimmed = line.trim();
          if (trimmed.isEmpty) continue;
          yield* _parseLine(trimmed);
        }
      }

      final last = buffer.trim();
      if (last.isNotEmpty) {
        yield* _parseLine(last);
      }
    } on DioException catch (e) {
      throw Exception(
        'Erro na API da Frequência40: ${e.message ?? e.toString()}',
      );
    } catch (e) {
      throw Exception('Erro no streaming: $e');
    }
  }

  Stream<ChatStreamEvent> _parseLine(String trimmed) async* {
    try {
      final json = jsonDecode(trimmed) as Map<String, dynamic>;

      final meta = json['gama_meta'] as Map<String, dynamic>?;
      if (meta != null) {
        final saved = meta['memory_saved'] as String?;
        final phase = meta['phase'] as String?;
        final query = meta['web_search'] as String?;
        List<WebSource>? sources;
        final rawSources = meta['sources'];
        if (rawSources is List) {
          sources = rawSources
              .whereType<Map>()
              .map((e) => WebSource.fromJson(Map<String, dynamic>.from(e)))
              .where((s) => s.url.isNotEmpty)
              .toList();
        }
        yield ChatStreamEvent.meta(
          phase: phase,
          webSearchQuery: query,
          sources: sources,
          memorySaved: saved,
        );
        return;
      }

      if (json['error'] != null && json['message'] is Map) {
        final content =
            (json['message'] as Map)['content']?.toString() ??
            json['error'].toString();
        if (content.isNotEmpty) yield ChatStreamEvent.token(content);
        return;
      }

      final message = json['message'] as Map<String, dynamic>?;
      if (message != null) {
        final content = message['content'] as String? ?? '';
        if (content.isNotEmpty) yield ChatStreamEvent.token(content);
      }
    } catch (_) {}
  }
}
