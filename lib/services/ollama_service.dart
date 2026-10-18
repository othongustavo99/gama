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
import 'context_manager.dart';

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
  final bool truncated;
  final bool done;

  const ChatStreamEvent._({
    this.token,
    this.memorySaved,
    this.phase,
    this.webSearchQuery,
    this.sources,
    this.imageBase64,
    this.imageMime,
    this.artifact,
    this.truncated = false,
    this.done = false,
  });

  factory ChatStreamEvent.token(String t) => ChatStreamEvent._(token: t);
  factory ChatStreamEvent.completed() => const ChatStreamEvent._(done: true);

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
    bool truncated = false,
  }) => ChatStreamEvent._(
    phase: phase,
    webSearchQuery: webSearchQuery,
    sources: sources,
    memorySaved: memorySaved,
    imageBase64: imageBase64,
    imageMime: imageMime,
    artifact: artifact,
    truncated: truncated,
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
  final responseData = error.response?.data;
  final rawDetail = responseData is Map ? responseData['detail'] : null;
  final serverDetail = rawDetail is String
      ? rawDetail.trim().replaceAll(RegExp(r'[\r\n\t]+'), ' ')
      : null;
  final boundedDetail = serverDetail == null
      ? null
      : (serverDetail.length > 500
            ? '${serverDetail.substring(0, 500)}…'
            : serverDetail);
  if (status == 401) {
    return const ChatApiException(
      'A sessão Google expirou ou não pôde ser renovada. Entre novamente e tente de novo.',
      retryable: false,
    );
  }
  if (status == 403) {
    return const ChatApiException(
      'A conta autenticada não tem permissão para esta operação.',
      retryable: false,
    );
  }
  if (status == 429) {
    return const ChatApiException(
      'O servidor está ocupado ou atingiu o limite de requisições. Aguarde um pouco e tente novamente.',
    );
  }
  if (status != null && status >= 500) {
    return const ChatApiException(
      'O servidor está temporariamente indisponível. Tente novamente em instantes.',
    );
  }
  if (error.type == DioExceptionType.connectionTimeout ||
      error.type == DioExceptionType.connectionError ||
      error.type == DioExceptionType.sendTimeout ||
      error.type == DioExceptionType.receiveTimeout) {
    return const ChatApiException(
      'Sem conexão com a Gama. Verifique a internet e tente novamente.',
    );
  }
  if (status == 413) {
    return const ChatApiException(
      'A conversa ou os anexos excederam o limite do servidor. Tente novamente com um histórico menor ou menos anexos.',
      retryable: false,
    );
  }
  if (status == 422) {
    return const ChatApiException(
      'A solicitação enviada está inválida. Confira os campos e anexos e tente novamente.',
      retryable: false,
    );
  }
  if (boundedDetail != null && boundedDetail.isNotEmpty) {
    return ChatApiException(boundedDetail, retryable: false);
  }
  return const ChatApiException(
    'Não foi possível concluir a solicitação. Tente novamente.',
  );
}

Future<ChatApiException> _friendlyDioExceptionAsync(DioException error) async {
  final data = error.response?.data;
  if (data is ResponseBody) {
    try {
      final body = await utf8.decoder.bind(data.stream).join();
      dynamic decoded;
      try {
        decoded = jsonDecode(body);
      } catch (_) {
        decoded = body;
      }
      final response = error.response;
      if (response != null) {
        return _friendlyDioException(
          DioException(
            requestOptions: error.requestOptions,
            response: Response<dynamic>(
              requestOptions: error.requestOptions,
              data: decoded,
              statusCode: response.statusCode,
              statusMessage: response.statusMessage,
              headers: response.headers,
              isRedirect: response.isRedirect,
              redirects: response.redirects,
              extra: response.extra,
            ),
            type: error.type,
            message: error.message,
          ),
        );
      }
    } catch (_) {}
  }
  return _friendlyDioException(error);
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
      _dio.interceptors.add(GammaAuthInterceptor(client: _dio));
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
      throw Exception(
        'Não foi possível listar os modelos. Verifique a conexão e tente novamente.',
      );
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
      final recentMessages = ContextManager().buildContext(messages);
      final requestMessages = MessageSanitize.historyForApi(
        recentMessages
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
          if (images != null &&
              images.isNotEmpty &&
              pluginFlags['attachments'] != false &&
              pluginFlags['vision'] != false)
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
          await for (final event in _parseLine(trimmed)) {
            yield event;
            if (event.done) return;
          }
        }
      }

      final last = buffer.trim();
      if (last.isNotEmpty) {
        await for (final event in _parseLine(last)) {
          yield event;
          if (event.done) return;
        }
      }
    } on DioException catch (e) {
      throw await _friendlyDioExceptionAsync(e);
    } on ChatApiException {
      rethrow;
    } catch (_) {
      throw const ChatApiException(
        'Ocorreu um erro ao receber a resposta. Tente novamente.',
      );
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
      final error = json['error'].toString().trim();
      final lowerError = error.toLowerCase();
      final detail = json['detail']?.toString().trim() ?? '';
      final lowerDetail = detail.toLowerCase();
      if (lowerError.contains('401') ||
          lowerError.contains('403') ||
          lowerDetail.contains('api key')) {
        throw _friendlyDioException(
          DioException(
            requestOptions: RequestOptions(path: '/chat'),
            response: Response<dynamic>(
              requestOptions: RequestOptions(path: '/chat'),
              statusCode: lowerError.contains('403') ? 403 : 401,
              data: json,
            ),
            type: DioExceptionType.badResponse,
          ),
        );
      }
      if (lowerError.contains('429') || lowerError.contains('rate limit')) {
        throw const ChatApiException(
          'O servidor está ocupado ou atingiu o limite de requisições. Aguarde um pouco e tente novamente.',
        );
      }
      if (error.isNotEmpty) {
        throw ChatApiException(
          error,
          retryable: !lowerError.contains('limite'),
        );
      }
      throw ChatApiException(
        detail.isNotEmpty
            ? detail
            : 'A Gama não conseguiu concluir a resposta. Tente novamente.',
      );
    }

    if (json['done'] == true) {
      final finalMessage = json['message'];
      if (finalMessage is Map) {
        final finalContent = finalMessage['content']?.toString() ?? '';
        if (finalContent.isNotEmpty) yield ChatStreamEvent.token(finalContent);
      }
      yield ChatStreamEvent.completed();
      return;
    }

    final meta = json['gama_meta'];
    if (meta is Map) {
      final m = Map<String, dynamic>.from(meta);
      final saved = m['memory_saved'] as String?;
      final truncated = m['finish_reason'] == 'length';
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
        truncated: truncated,
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
