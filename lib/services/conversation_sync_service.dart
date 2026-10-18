import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../core/constants.dart';
import 'auth_interceptor.dart';
import '../models/message.dart';
import 'conversation_service.dart';
import 'identity_service.dart';
import 'settings_service.dart';

/// Sincroniza conversas Hive ↔ Railway (`/conversations`).
/// O backend deriva a identidade do Bearer Google validado; `X-User-Id` fica
/// apenas como compatibilidade com servidores locais no modo legado.
/// Com o mesmo login Google no Android e no Windows, o histórico fica igual.
class ConversationSyncService {
  ConversationSyncService._();
  static final ConversationSyncService instance = ConversationSyncService._();

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 12),
      receiveTimeout: const Duration(seconds: 45),
      sendTimeout: const Duration(seconds: 45),
      validateStatus: (_) => true,
    ),
  );

  bool _syncing = false;
  DateTime? _lastFullSync;

  Dio _client() {
    if (!_dio.interceptors.any((i) => i is GammaAuthInterceptor)) {
      _dio.interceptors.add(GammaAuthInterceptor(client: _dio));
    }
    _dio.options.baseUrl = SettingsService.instance.baseUrl;
    _dio.options.headers['X-User-Id'] = IdentityService.instance.userId;
    _dio.options.headers['Accept'] = 'application/json';
    _dio.options.headers.addAll(AppConstants.authHeaders);
    return _dio;
  }

  /// Sincronização completa: puxa do servidor e envia o que o local tem de mais novo.
  Future<void> syncAll({bool force = false}) async {
    if (_syncing) return;
    if (!force &&
        _lastFullSync != null &&
        DateTime.now().difference(_lastFullSync!) <
            const Duration(seconds: 8)) {
      return;
    }

    _syncing = true;
    try {
      final remote = await _pullRemote();
      await _mergeRemoteIntoLocal(remote);
      await _pushLocalToRemote();
      _lastFullSync = DateTime.now();
      ConversationService.instance.notifyListeners();
    } catch (e, st) {
      debugPrint('conversation sync: $e');
      debugPrintStack(stackTrace: st);
    } finally {
      _syncing = false;
    }
  }

  /// Envia uma conversa específica (após mensagem / rename / pin).
  Future<void> pushConversation(String id) async {
    final local = ConversationService.instance;
    if (!local.conversationHasMessages(id)) return;

    final conv = local.conversationById(id);
    if (conv == null) return;

    final messages = local.getMessages(id);
    try {
      final res = await _client().put(
        '/conversations/$id',
        data: {
          'id': conv.id,
          'title': conv.title,
          'isPinned': conv.isPinned,
          'createdAt': conv.createdAt.toUtc().toIso8601String(),
          'updatedAt': conv.updatedAt.toUtc().toIso8601String(),
          'messages': [
            for (final m in messages)
              {
                'id': m.id,
                'role': m.role,
                'content': m.content,
                'conversationId': m.conversationId,
                'timestamp': m.timestamp.toUtc().toIso8601String(),
                'attachmentMetadataJson': m.attachmentMetadataJson,
                'variants': m.variants,
                'selectedVariantIndex': m.selectedVariantIndex,
              },
          ],
        },
      );
      if ((res.statusCode ?? 0) >= 400) {
        debugPrint(
          'push conversation $id failed: ${res.statusCode} ${res.data}',
        );
      }
    } catch (e) {
      debugPrint('push conversation $id: $e');
    }
  }

  /// Envia só a mensagem que mudou; evita reenviar o histórico em cada turno.
  Future<void> pushMessage(Message message) async {
    try {
      final conv = ConversationService.instance.conversationById(
        message.conversationId,
      );
      if (conv == null) return;
      final res = await _client().put(
        '/conversations/${message.conversationId}/messages/${message.id}',
        data: _messagePayload(message),
      );
      if ((res.statusCode ?? 0) >= 400) {
        debugPrint(
          'push message ${message.id} failed: ${res.statusCode} ${res.data}',
        );
      }
    } catch (e) {
      debugPrint('push message ${message.id}: $e');
    }
  }

  Future<void> pushConversationMetadata(String id) async {
    final conv = ConversationService.instance.conversationById(id);
    if (conv == null) return;
    try {
      final res = await _client().patch(
        '/conversations/$id',
        data: {
          'title': conv.title,
          'isPinned': conv.isPinned,
          'updatedAt': conv.updatedAt.toUtc().toIso8601String(),
        },
      );
      if ((res.statusCode ?? 0) >= 400) {
        debugPrint(
          'push conversation metadata $id failed: ${res.statusCode} ${res.data}',
        );
      }
    } catch (e) {
      debugPrint('push conversation metadata $id: $e');
    }
  }

  Future<void> deleteMessages(String conversationId, List<String> ids) async {
    if (ids.isEmpty) return;
    try {
      final res = await _client().post(
        '/conversations/$conversationId/messages/delete',
        data: {'ids': ids},
      );
      if ((res.statusCode ?? 0) >= 400) {
        debugPrint(
          'delete remote messages $conversationId failed: ${res.statusCode} ${res.data}',
        );
      }
    } catch (e) {
      debugPrint('delete remote messages $conversationId: $e');
    }
  }

  Map<String, dynamic> _messagePayload(Message m) => {
    'id': m.id,
    'role': m.role,
    'content': m.content,
    'conversationId': m.conversationId,
    'timestamp': m.timestamp.toUtc().toIso8601String(),
    'attachmentMetadataJson': m.attachmentMetadataJson,
    'variants': m.variants,
    'selectedVariantIndex': m.selectedVariantIndex,
  };

  Future<void> deleteRemote(String id) async {
    try {
      await _client().delete('/conversations/$id');
    } catch (e) {
      debugPrint('delete remote conversation $id: $e');
    }
  }

  Future<List<Map<String, dynamic>>> _pullRemote() async {
    final res = await _client().get(
      '/conversations',
      queryParameters: {'full': true},
    );
    final code = res.statusCode ?? 0;
    if (code >= 400) {
      debugPrint('pull conversations failed: $code ${res.data}');
      return const [];
    }
    final data = res.data is Map
        ? Map<String, dynamic>.from(res.data as Map)
        : <String, dynamic>{};
    final list = data['conversations'] as List<dynamic>? ?? [];
    return list
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  Future<void> _mergeRemoteIntoLocal(List<Map<String, dynamic>> remote) async {
    final local = ConversationService.instance;
    for (final r in remote) {
      final id = (r['id'] ?? '').toString();
      if (id.isEmpty) continue;

      final remoteUpdated = _parseDate(r['updatedAt'] ?? r['updated_at']);
      final existing = local.conversationById(id);
      final deletedIds = (r['deletedMessageIds'] as List<dynamic>? ?? const [])
          .map((value) => value.toString())
          .toSet();

      if (existing != null) {
        final locallyDeleted = local
            .getMessages(id)
            .where((message) => deletedIds.contains(message.id))
            .toList();
        if (locallyDeleted.isNotEmpty) {
          await local.deleteMessages(locallyDeleted, sync: false);
        }
        // Local mais novo → não sobrescreve; será enviado no push
        if (existing.updatedAt.isAfter(remoteUpdated)) continue;
      }

      final title = (r['title'] ?? 'Nova conversa').toString();
      final isPinned = r['isPinned'] == true || r['is_pinned'] == true;
      final createdAt = _parseDate(r['createdAt'] ?? r['created_at']);
      final messagesRaw = r['messages'] as List<dynamic>? ?? [];

      await local.applyRemoteConversation(
        id: id,
        title: title,
        isPinned: isPinned,
        createdAt: createdAt,
        updatedAt: remoteUpdated,
        messages: [
          for (final raw in messagesRaw)
            if (raw is Map &&
                !deletedIds.contains((raw['id'] ?? '').toString()))
              Message(
                id: (raw['id'] ?? '').toString(),
                role: (raw['role'] ?? 'assistant').toString(),
                content: (raw['content'] ?? '').toString(),
                conversationId: id,
                timestamp: _parseDate(raw['timestamp']),
                attachmentMetadataJson: (raw['attachmentMetadataJson'] ?? '')
                    .toString(),
                variants: raw['variants'] is List
                    ? (raw['variants'] as List)
                          .map((v) => v.toString())
                          .toList()
                    : null,
                selectedVariantIndex:
                    int.tryParse(
                      (raw['selectedVariantIndex'] ?? 0).toString(),
                    ) ??
                    0,
              ),
        ],
      );
    }
  }

  Future<void> _pushLocalToRemote() async {
    final local = ConversationService.instance;
    final all = [...local.pinnedConversations, ...local.recentConversations];
    for (final c in all) {
      await pushConversation(c.id);
    }
  }

  static DateTime _parseDate(dynamic value) {
    if (value == null)
      return DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    if (value is int) {
      final v = value > 1000000000000 ? value : value * 1000;
      return DateTime.fromMillisecondsSinceEpoch(v, isUtc: true);
    }
    if (value is double) {
      final v = value > 1e12 ? value.toInt() : (value * 1000).toInt();
      return DateTime.fromMillisecondsSinceEpoch(v, isUtc: true);
    }
    final s = value.toString().trim();
    if (s.isEmpty) return DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    try {
      return DateTime.parse(s).toUtc();
    } catch (_) {
      return DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    }
  }
}
