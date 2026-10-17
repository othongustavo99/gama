import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../core/constants.dart';
import 'auth_interceptor.dart';
import '../models/message.dart';
import '../utils/message_sanitize.dart';
import 'identity_service.dart';
import 'settings_service.dart';
import 'plugin_settings_service.dart';

class ChatStreamEvent {
  final String? token;
  final String? memorySaved;
  final String? phase; // searching | thinking | typing | generating_image | image_ready | video_generating
  final String? webSearchQuery;
  final List<Map<String, dynamic>>? sources;
  /// Imagem gerada (base64 puro, sem data: prefix)
  final String? imageBase64;
  final String? imageMime;
  final Map<String, dynamic>? artifact;

  const ChatStreamEvent._({
    this.token,
    this.memorySaved,
    this.phase,
    this.webSearchQuery,
    this.sources,
    this.imageBase64,
    this.imageMime,
    this.artifact,
  });

  factory ChatStreamEvent.token(String t) => ChatStreamEvent._(token: t);

  factory ChatStreamEvent.memorySaved(String fact) =>
      ChatStreamEvent._(memorySaved: fact);

  factory ChatStreamEvent.meta({
    String? phase,
    String? webSearchQuery,
    List<Map<String, dynamic>>? sources,
    String? memorySaved,
    String? imageBase64,
    String? imageMime,
    Map<String, dynamic>? artifact,
  }) => ChatStreamEvent._(
    phase: phase,
    webSearchQuery: webSearchQuery,
    sources: sources,
    memorySaved: memorySaved,
    imageBase64: imageBase64,
    imageMime: imageMime,
    artifact: artifact,
  );
}


class ChatApiException implements Exception {
  final String message;
  final bool retryable;
  const ChatApiException(this.message, {this.retryable = true});

  @override
  String toString() => message;
}

ChatApiException _friendlyDioException(DioException error) {
  final status = error.response?.statusCode;
  if (status == 401 || status == 403) {
    if (AppConstants.apiKey.isEmpty) {
      return const ChatApiException(
        'A API recusou o acesso (401/403). Este build está sem GAMA_API_KEY. '
        'Gere o APK com --dart-define=GAMA_API_KEY=SUA_CHAVE e confirme que a chave corresponde à configurada no Railway. '
        'Não coloque uma chave privada em um APK distribuído publicamente.',
        retryable: false,
      );
    }
    return const ChatApiException(
      'A API recusou o acesso (401/403). Confira a chave configurada no build e a autenticação da sessão.',
      retryable: false,
    );
  }
  if (status == 429) {
    return const ChatApiException('O servidor está ocupado ou atingiu o limite de requisições. Aguarde um pouco e tente novamente.');
  }
  if (status != null && status >= 500) {
    return const ChatApiException('O servidor está temporariamente indisponível. Tente novamente em instantes.');
  }
  if (error.type == DioExceptionType.connectionTimeout ||
      error.type == DioExceptionType.connectionError ||
      error.type == DioExceptionType.sendTimeout ||
      error.type == DioExceptionType.receiveTimeout) {
    return const ChatApiException('Sem conexão com a Gama. Verifique a internet e tente novamente.');
  }
  if (status == 413) {
    return const ChatApiException('O conteúdo enviado é grande demais. Remova alguns anexos e tente novamente.', retryable: false);
  }
  return const ChatApiException('Não foi possível concluir a solicitação. Tente novamente.');
}

class OllamaService {
  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(minutes: 12),
      sendTimeout: const Duration(seconds: 60),
      headers: const {'Accept': 'application/json'},
    ),
  );

  Dio _client() {
    // Mantém uma única instância do Dio para reaproveitar conexões HTTP.
    // A URL continua podendo ser alterada pelas configurações do app.
    if (!_dio.interceptors.any((i) => i is GammaAuthInterceptor)) {
      _dio.interceptors.add(GammaAuthInterceptor());
    }
    _dio.options.baseUrl = SettingsService.instance.baseUrl;
    _dio.options.headers.addAll(AppConstants.authHeaders);
    return _dio;
  }

  /// Pede ao mesmo modelo selecionado um título curto para o histórico.
  /// Falhas são tratadas pelo chamador com um título local de fallback.
  Future<String?> generateConversationTitle({
    required String userMessage,
    required String assistantMessage,
  }) async {
    try {
      final dio = _client();
      final response = await dio.post(
        '/conversations/title',
        data: {
          'model': SettingsService.instance.model,
          'user_message': userMessage.length > 5000
              ? userMessage.substring(0, 5000)
              : userMessage,
          'assistant_message': assistantMessage.length > 5000
              ? assistantMessage.substring(0, 5000)
              : assistantMessage,
        },
        options: Options(receiveTimeout: const Duration(seconds: 25)),
      );
      if (response.data is! Map) return null;
      final title = (response.data as Map)['title']?.toString().trim();
      if (title == null || title.isEmpty) return null;
      return title;
    } catch (_) {
      return null;
    }
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
      if (e.response?.statusCode == 401 || e.response?.statusCode == 403) {
        throw _friendlyDioException(e);
      }
      throw Exception('Não foi possível listar os modelos. Verifique a conexão e tente novamente.');
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

    /// ID da conversa no app — mantém project_id/ZIP entre mensagens.
    String? conversationId,
  }) async* {
    final selectedModel = model ?? SettingsService.instance.model;
    final dio = _client();
    final pluginFlags = await PluginSettingsService.instance.load();

    try {
      // Sanitiza histórico: tira base64 de imagens e dumps grandes de ZIP
      final requestMessages = MessageSanitize.historyForApi(
        messages.map((m) => {'role': m.role, 'content': m.content}).toList(),
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
          if (images != null && images.isNotEmpty &&
              pluginFlags['attachments'] != false && pluginFlags['vision'] != false)
            'images': images,
          'user_id': IdentityService.instance.userId,
          'auto_memory': pluginFlags['memory'] ?? true,
          'plugins': pluginFlags,
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
      throw _friendlyDioException(e);
    } on ChatApiException {
      rethrow;
    } catch (_) {
      throw const ChatApiException('Ocorreu um erro ao receber a resposta. Tente novamente.');
    }
  }

  Stream<ChatStreamEvent> _parseLine(String trimmed) async* {
    Map<String, dynamic> json;
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is! Map) return;
      json = Map<String, dynamic>.from(decoded);
    } catch (_) {
      // Linhas auxiliares/eventuais keep-alives não são mensagens visíveis.
      return;
    }

    if (json['error'] != null) {
      final error = json['error'].toString().toLowerCase();
      final detail = json['detail']?.toString().toLowerCase() ?? '';
      if (error.contains('401') || error.contains('403') || detail.contains('api key')) {
        throw _friendlyDioException(DioException(
          requestOptions: RequestOptions(path: '/chat'),
          response: Response<dynamic>(
            requestOptions: RequestOptions(path: '/chat'),
            statusCode: error.contains('403') ? 403 : 401,
            data: json,
          ),
          type: DioExceptionType.badResponse,
        ));
      }
      if (error.contains('429') || error.contains('rate limit')) {
        throw const ChatApiException('O servidor está ocupado ou atingiu o limite de requisições. Aguarde um pouco e tente novamente.');
      }
      if (error.contains('500') || error.contains('502') || error.contains('503') || error.contains('504')) {
        throw const ChatApiException('O servidor está temporariamente indisponível. Tente novamente em instantes.');
      }
      throw const ChatApiException('A Gama não conseguiu concluir a resposta. Tente novamente.');
    }

    final meta = json['gama_meta'];
    if (meta is Map) {
      final m = Map<String, dynamic>.from(meta);
      final saved = m['memory_saved'] as String?;
      final phase = m['phase'] as String?;
      final query = m['web_search'] as String?;
      String? imgB64;
      String? imgMime;
      List<Map<String, dynamic>>? sources;
      final rawSources = m['sources'];
      if (rawSources is List) {
        sources = rawSources
            .whereType<Map>()
            .map((item) => Map<String, dynamic>.from(item))
            .toList(growable: false);
      }
      Map<String, dynamic>? artifact;
      final rawArtifact = m['artifact'];
      if (rawArtifact is Map) artifact = Map<String, dynamic>.from(rawArtifact);
      final img = m['image'];
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
        artifact: artifact,
      );
      return;
    }

    final message = json['message'];
    if (message is Map) {
      final content = message['content']?.toString() ?? '';
      if (content.isNotEmpty) yield ChatStreamEvent.token(content);
    }
  }
}
