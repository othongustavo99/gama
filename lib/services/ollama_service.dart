import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../models/message.dart';
import 'settings_service.dart';

class OllamaService {
  Dio _createDio() {
    return Dio(
      BaseOptions(
        baseUrl: SettingsService.instance.baseUrl,
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(minutes: 5),
        sendTimeout: const Duration(seconds: 30),
      ),
    );
  }

  /// Lista os modelos disponíveis através
  /// da API da Frequência40.
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

  /// Testa a API da Frequência40 e o Ollama.
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

      if (response.statusCode != 200) {
        return false;
      }

      final data = response.data as Map<String, dynamic>;

      return data['ollama'] == 'online';
    } catch (_) {
      return false;
    }
  }

  /// Envia uma conversa para a API da Frequência40
  /// e recebe a resposta em streaming.
  ///
  /// A personalidade, o prompt do sistema e o controle
  /// do contexto agora são responsabilidade do Gama Core
  /// no backend.
  Stream<String> chatStream({
    required List<Message> messages,
    String? model,
  }) async* {
    final selectedModel = model ?? SettingsService.instance.model;

    final dio = _createDio();

    try {
      /*
       * O Flutter não monta mais o system prompt.
       *
       * Também não precisamos mais limitar o contexto aqui.
       *
       * O Gama Core no backend será responsável por:
       *
       * - personalidade
       * - system prompt
       * - contexto
       * - memória futuramente
       */
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

      final responseStream = response.data.stream as Stream<List<int>>;

      final lines = utf8.decoder.bind(responseStream);

      String buffer = '';

      await for (final chunk in lines) {
        buffer += chunk;

        while (buffer.contains('\n')) {
          final index = buffer.indexOf('\n');

          final line = buffer.substring(0, index).trim();

          buffer = buffer.substring(index + 1);

          if (line.isEmpty) {
            continue;
          }

          try {
            final json = jsonDecode(line) as Map<String, dynamic>;

            /*
             * Tratamento de erro enviado pela API.
             */
            final error = json['error'] as String?;

            if (error != null && error.isNotEmpty) {
              throw Exception(error);
            }

            /*
             * Compatibilidade com o streaming atual
             * do Ollama.
             *
             * Exemplo:
             *
             * {
             *   "message": {
             *     "content": "Olá"
             *   }
             * }
             */
            final message = json['message'] as Map<String, dynamic>?;

            final content = message?['content'] as String?;

            if (content != null && content.isNotEmpty) {
              yield content;
            }

            /*
             * O Ollama informa o fim da geração
             * através de:
             *
             * "done": true
             */
            if (json['done'] == true) {
              return;
            }
          } on FormatException {
            /*
             * Ignora linhas que não sejam JSON válido.
             *
             * Isso evita que um pedaço inesperado do
             * streaming derrube toda a conversa.
             */
            continue;
          }
        }
      }

      /*
       * Caso o último chunk não termine com "\n",
       * ainda tentamos processá-lo.
       */
      final remaining = buffer.trim();

      if (remaining.isNotEmpty) {
        try {
          final json = jsonDecode(remaining) as Map<String, dynamic>;

          final error = json['error'] as String?;

          if (error != null && error.isNotEmpty) {
            throw Exception(error);
          }

          final message = json['message'] as Map<String, dynamic>?;

          final content = message?['content'] as String?;

          if (content != null && content.isNotEmpty) {
            yield content;
          }
        } on FormatException {
          // Ignora último fragmento inválido.
        }
      }
    } on DioException catch (e) {
      String message = e.message ?? 'Erro desconhecido';

      if (e.response?.data != null) {
        try {
          final data = e.response!.data;

          if (data is Map<String, dynamic>) {
            final apiError = data['detail'] ?? data['error'];

            if (apiError != null) {
              message = apiError.toString();
            }
          }
        } catch (_) {
          // Mantém a mensagem original.
        }
      }

      throw Exception('Erro na API da Frequência40: $message');
    } catch (e) {
      throw Exception('Erro no streaming: $e');
    }
  }
}
