import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../models/message.dart';
import 'settings_service.dart';

/// Eventos do stream: texto da resposta ou meta da API (ex.: memória gravada).
class ChatStreamEvent {
  final String? token;
  final String? memorySaved;

  const ChatStreamEvent._({this.token, this.memorySaved});

  factory ChatStreamEvent.token(String t) => ChatStreamEvent._(token: t);

  factory ChatStreamEvent.memorySaved(String fact) =>
      ChatStreamEvent._(memorySaved: fact);
}

class OllamaService {
  Dio _createDio() {
    return Dio(
      BaseOptions(
        baseUrl: SettingsService.instance.baseUrl,
        connectTimeout: const Duration(seconds: 10),
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
      return data['ollama'] == 'online';
    } catch (_) {
      return false;
    }
  }

  /// Stream de eventos (tokens + meta de memória).
  Stream<ChatStreamEvent> chatStream({
    required List<Message> messages,
    String? model,
  }) async* {
    final selectedModel = model ?? SettingsService.instance.model;
    final dio = _createDio();

    try {
      final requestMessages = messages
          .map((message) => message.toJson())
          .toList();

      final response = await dio.post(
        '/chat',
        data: {'model': selectedModel, 'messages': requestMessages},
        options: Options(
          responseType: ResponseType.stream,
          headers: {
            'Accept': 'application/x-ndjson',
            'Content-Type': 'application/json',
          },
        ),
      );

      final body = response.data;
      if (body is! ResponseBody) {
        throw Exception('Resposta de stream inválida da API');
      }
      final lines = utf8.decoder.bind(body.stream);

      String buffer = '';

      await for (final chunk in lines) {
        buffer += chunk;

        while (buffer.contains('\n')) {
          final index = buffer.indexOf('\n');
          final line = buffer.substring(0, index).trim();
          buffer = buffer.substring(index + 1);

          if (line.isEmpty) continue;

          try {
            final json = jsonDecode(line) as Map<String, dynamic>;

            // Meta da Frequência40 (memória gravada, etc.)
            final meta = json['gama_meta'] as Map<String, dynamic>?;
            if (meta != null) {
              final saved = meta['memory_saved'] as String?;
              if (saved != null && saved.isNotEmpty) {
                yield ChatStreamEvent.memorySaved(saved);
              }
              continue;
            }

            final error = json['error'] as String?;
            if (error != null && error.isNotEmpty) {
              throw Exception(error);
            }

            final message = json['message'] as Map<String, dynamic>?;
            final content = message?['content'] as String?;
            if (content != null && content.isNotEmpty) {
              yield ChatStreamEvent.token(content);
            }

            if (json['done'] == true) {
              return;
            }
          } on FormatException {
            continue;
          }
        }
      }

      final remaining = buffer.trim();
      if (remaining.isNotEmpty) {
        try {
          final json = jsonDecode(remaining) as Map<String, dynamic>;
          final meta = json['gama_meta'] as Map<String, dynamic>?;
          if (meta != null) {
            final saved = meta['memory_saved'] as String?;
            if (saved != null && saved.isNotEmpty) {
              yield ChatStreamEvent.memorySaved(saved);
            }
          }
          final message = json['message'] as Map<String, dynamic>?;
          final content = message?['content'] as String?;
          if (content != null && content.isNotEmpty) {
            yield ChatStreamEvent.token(content);
          }
        } on FormatException {
          // ignora
        }
      }
    } on DioException catch (e) {
      String message = e.message ?? 'Erro desconhecido';
      if (e.response?.data != null) {
        try {
          final data = e.response!.data;
          if (data is Map<String, dynamic>) {
            final apiError = data['detail'] ?? data['error'];
            if (apiError != null) message = apiError.toString();
          }
        } catch (_) {}
      }
      throw Exception('Erro na API da Frequência40: $message');
    } catch (e) {
      throw Exception('Erro no streaming: $e');
    }
  }
}
