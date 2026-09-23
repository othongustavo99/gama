import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../core/constants.dart';
import '../models/message.dart';

class OllamaService {
  final Dio _dio = Dio(
    BaseOptions(
      baseUrl: AppConstants.ollamaBaseUrl,
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(minutes: 3),
    ),
  );

  /// Versão antiga (não-streaming) - mantida caso precise
  Future<String> chat({
    required List<Message> messages,
    String model = AppConstants.defaultModel,
  }) async {
    try {
      final fullMessages = [
        {'role': 'system', 'content': AppConstants.systemPrompt},
        ...messages.map((m) => m.toJson()),
      ];

      final response = await _dio.post(
        '/api/chat',
        data: {'model': model, 'messages': fullMessages, 'stream': false},
      );

      return response.data['message']['content'] as String;
    } on DioException catch (e) {
      throw Exception('Erro ao conversar com Ollama: ${e.message}');
    }
  }

  /// Streaming real (NDJSON do Ollama)
  Stream<String> chatStream({
    required List<Message> messages,
    String model = AppConstants.defaultModel,
  }) async* {
    try {
      final fullMessages = [
        {'role': 'system', 'content': AppConstants.systemPrompt},
        ...messages.map((m) => m.toJson()),
      ];

      final response = await _dio.post(
        '/api/chat',
        data: {'model': model, 'messages': fullMessages, 'stream': true},
        options: Options(responseType: ResponseType.stream),
      );

      final stream = response.data.stream as Stream<List<int>>;
      String buffer = '';

      await for (final chunk in stream) {
        buffer += utf8.decode(chunk);

        // Ollama envia várias linhas JSON (NDJSON)
        while (buffer.contains('\n')) {
          final index = buffer.indexOf('\n');
          final line = buffer.substring(0, index).trim();
          buffer = buffer.substring(index + 1);

          if (line.isEmpty) continue;

          try {
            final json = jsonDecode(line) as Map<String, dynamic>;

            // Conteúdo parcial
            final content = json['message']?['content'] as String?;
            if (content != null && content.isNotEmpty) {
              yield content;
            }

            // Fim do stream
            if (json['done'] == true) {
              return;
            }
          } catch (_) {
            // ignora linhas malformadas
          }
        }
      }
    } on DioException catch (e) {
      throw Exception('Erro no streaming: ${e.message}');
    } catch (e) {
      throw Exception('Erro no streaming: $e');
    }
  }
}
