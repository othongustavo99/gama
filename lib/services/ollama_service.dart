import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../models/message.dart';
import '../utils/message_sanitize.dart';
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
  final String? phase; // searching | thinking | typing | generating_image | image_ready
  final String? webSearchQuery;
  final List<WebSource>? sources;
  /// Imagem gerada (base64 puro, sem data: prefix)
  final String? imageBase64;
  final String? imageMime;

  const ChatStreamEvent._({
    this.token,
    this.memorySaved,
    this.phase,
    this.webSearchQuery,
    this.sources,
    this.imageBase64,
    this.imageMime,
  });

  factory ChatStreamEvent.token(String t) => ChatStreamEvent._(token: t);

  factory ChatStreamEvent.memorySaved(String fact) =>
      ChatStreamEvent._(memorySaved: fact);

  factory ChatStreamEvent.meta({
    String? phase,
    String? webSearchQuery,
    List<WebSource>? sources,
    String? memorySaved,
    String? imageBase64,
    String? imageMime,
  }) => ChatStreamEvent._(
    phase: phase,
    webSearchQuery: webSearchQuery,
    sources: sources,
    memorySaved: memorySaved,
    imageBase64: imageBase64,
    imageMime: imageMime,
  );
}

class OllamaService {
  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(minutes: 5),
      sendTimeout: const Duration(seconds: 60),
      headers: const {'Accept': 'application/json'},
    ),
  );

  Dio _client() {
    // Mantém uma única instância do Dio para reaproveitar conexões HTTP.
    // A URL continua podendo ser alterada pelas configurações do app.
    _dio.options.baseUrl = SettingsService.instance.baseUrl;
    return _dio;
  }

  Future<List<String>> listModels() async {
    try {
      final dio = _client();
      final response = await dio.get(
        '/models',
        options: Options(receiveTimeout: const Duration(seconds: 15)),
      );
      final data = response.data is Map
          ? Map<String, dynamic>.from(response.data as Map)
          : <String, dynamic>{};
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
      final dio = _client();
      final response = await dio.get(
        '/health',
        options: Options(
          receiveTimeout: const Duration(seconds: 5),
          sendTimeout: const Duration(seconds: 5),
        ),
      );
      if (response.statusCode != 200) return false;
      final data = response.data is Map
          ? Map<String, dynamic>.from(response.data as Map)
          : <String, dynamic>{};
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
    bool voiceMode = false,
    /// 'conversar' | 'programar' — estilo da resposta no backend.
    String? chatMode,
  }) async* {
    final selectedModel = model ?? SettingsService.instance.model;
    final dio = _client();

    try {
      // Sanitiza histórico: tira base64 de imagens e dumps grandes de ZIP
      final requestMessages = MessageSanitize.historyForApi(
        messages
            .map((m) => {'role': m.role, 'content': m.content})
            .toList(),
      );

      // Em modo fala / conversar: reforça no pedido para a resposta ser
      // apenas frases naturais, sem listas, código, tabelas ou símbolos.
      if (voiceMode) {
        requestMessages.insert(0, {
          'role': 'system',
          'content':
              'Responda SOMENTE com frases curtas e naturais em português, '
              'como se estivesse falando em voz alta. '
              'PROIBIDO: listas, marcadores, numeração, código, tabelas, '
              'markdown, símbolos especiais (cifrão, barra, asterisco), '
              'abreviações (ex., etc., seg) e jargão técnico empilhado. '
              'Escreva as palavras por extenso. Se precisar citar tecnologia, '
              'fale em uma frase corrida, sem enumerar.',
        });
      } else if (chatMode == 'conversar') {
        requestMessages.insert(0, {
          'role': 'system',
          'content':
              'Modo conversa: responda de forma simples e natural, em frases '
              'completas. Evite código, tabelas, listas longas e abreviações. '
              'Prefira texto corrido fácil de ler em voz alta.',
        });
      }

      final response = await dio.post(
        '/chat',
        data: {
          'model': selectedModel,
          'messages': requestMessages,
          if (images != null && images.isNotEmpty) 'images': images,
          'user_id': IdentityService.instance.userId,
          'auto_memory': true,
          'voice_mode': voiceMode,
          if (chatMode != null) 'chat_mode': chatMode,
          if (conversationId != null && conversationId.isNotEmpty)
            'conversation_id': conversationId,
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
        String? imgB64;
        String? imgMime;
        final img = meta['image'];
        if (img is Map) {
          imgB64 = img['data']?.toString();
          imgMime = img['mime']?.toString() ?? 'image/png';
        }
        yield ChatStreamEvent.meta(
          phase: phase,
          webSearchQuery: query,
          sources: sources,
          memorySaved: saved,
          imageBase64: imgB64,
          imageMime: imgMime,
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
