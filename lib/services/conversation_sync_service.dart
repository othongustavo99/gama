import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/constants.dart';
import 'auth_interceptor.dart';
import 'auth_service.dart';
import '../models/message.dart';
import 'conversation_service.dart';
import 'identity_service.dart';
import 'settings_service.dart';
import '../utils/error_logger.dart';
import '../utils/conversation_sync_planner.dart';

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
  bool _syncingPendingGenerations = false;
  DateTime? _lastFullSync;
  static const _pendingGenerationsKey = 'gama_pending_generations';
  static const _pendingDeletesPrefix = 'gama_pending_message_deletes_';
  static const _remoteRevisionsPrefix = 'gama_sync_remote_revisions_v3_';
  static const _uploadedSnapshotsPrefix = 'gama_sync_uploaded_snapshots_v3_';
  Future<void> _pendingDeleteQueue = Future<void>.value();

  Future<bool> _hasGoogleSession() async {
    if (IdentityService.instance.provider != 'google') return false;
    try {
      final token = await AuthService.instance.bearerToken();
      return token != null && token.isNotEmpty;
    } catch (error, stack) {
      logSwallowed(error, stack);
      return false;
    }
  }

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

  /// Sincronização eficiente e conservadora:
  /// 1) lista metadados leves; 2) baixa somente as revisões alteradas;
  /// 3) envia conversas locais só quando o snapshot divergiu do último PUT.
  /// A versão sem syncRevision (backend antigo) sempre é baixada.
  Future<void> syncAll({bool force = false}) async {
    if (_syncing) return;
    if (!await _hasGoogleSession()) return;
    if (!force &&
        _lastFullSync != null &&
        DateTime.now().difference(_lastFullSync!) <
            const Duration(seconds: 8)) {
      return;
    }

    _syncing = true;
    try {
      await _flushPendingMessageDeletes();
      final storedRemote = await _readSyncCache(_remoteRevisionsPrefix);
      final storedUploaded = await _readSyncCache(_uploadedSnapshotsPrefix);
      final local = ConversationService.instance;
      // Não confie num checkpoint se os dados locais foram apagados.
      final known = <String, String>{
        for (final entry in storedRemote.entries)
          if (!force && local.conversationById(entry.key) != null)
            entry.key: entry.value,
      };
      final delta = await _pullRemoteChanges(known);
      final revisions = delta.revisions;
      final toMerge = delta.changed;
      await _mergeRemoteIntoLocal(toMerge);

      // Só persistir checkpoints após todos os envios concluírem sem erro.
      final uploaded = await _pushChangedLocalToRemote(
        force ? <String, String>{} : storedUploaded,
        revisions,
      );
      await _writeSyncCache(_remoteRevisionsPrefix, revisions);
      await _writeSyncCache(_uploadedSnapshotsPrefix, uploaded);
      _lastFullSync = DateTime.now();
      local.notifyListeners();
    } catch (e, st) {
      debugPrint('conversation sync: $e');
      debugPrintStack(stackTrace: st);
    } finally {
      _syncing = false;
    }
  }

  String _syncCacheKey(String prefix) =>
      '$prefix${IdentityService.instance.userId}';

  Future<Map<String, String>> _readSyncCache(String prefix) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_syncCacheKey(prefix));
    if (raw == null || raw.isEmpty) return <String, String>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return <String, String>{};
      return decoded.map(
        (key, value) => MapEntry(key.toString(), value.toString()),
      );
    } catch (error, stack) {
      logSwallowed(error, stack, context: 'ler cache da sincronização');
      return <String, String>{};
    }
  }

  Future<void> _writeSyncCache(
    String prefix,
    Map<String, String> entries,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final key = _syncCacheKey(prefix);
    if (entries.isEmpty) {
      await prefs.remove(key);
    } else {
      await prefs.setString(key, jsonEncode(entries));
    }
  }

  Future<Map<String, String>> _readPendingGenerations() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_pendingGenerationsKey);
    if (raw == null || raw.isEmpty) return <String, String>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return <String, String>{};
      return decoded.map(
        (key, value) => MapEntry(key.toString(), value.toString()),
      );
    } catch (error, stack) {
      logSwallowed(error, stack);
      return <String, String>{};
    }
  }

  Future<void> _writePendingGenerations(Map<String, String> pending) async {
    final prefs = await SharedPreferences.getInstance();
    if (pending.isEmpty) {
      await prefs.remove(_pendingGenerationsKey);
    } else {
      await prefs.setString(_pendingGenerationsKey, jsonEncode(pending));
    }
  }

  Future<void> trackPendingGeneration({
    required String conversationId,
    required String assistantMessageId,
  }) async {
    if (IdentityService.instance.provider != 'google' ||
        conversationId.isEmpty ||
        assistantMessageId.isEmpty) {
      return;
    }
    final pending = await _readPendingGenerations();
    pending[assistantMessageId] = conversationId;
    await _writePendingGenerations(pending);
  }

  Future<void> clearPendingGeneration(String assistantMessageId) async {
    if (assistantMessageId.isEmpty) return;
    final pending = await _readPendingGenerations();
    if (pending.remove(assistantMessageId) != null) {
      await _writePendingGenerations(pending);
    }
  }

  /// Recolhe respostas que o servidor terminou após o app perder a conexão.
  Future<void> syncPendingGenerations() async {
    if (_syncingPendingGenerations) return;
    _syncingPendingGenerations = true;
    try {
      final pending = await _readPendingGenerations();
      if (pending.isEmpty || !await _hasGoogleSession()) return;
      for (final entry in Map<String, String>.from(pending).entries) {
        try {
          final response = await _client().get('/conversations/${entry.value}');
          if ((response.statusCode ?? 0) >= 400 || response.data is! Map) {
            continue;
          }
          final conversation = Map<String, dynamic>.from(response.data as Map);
          final rawMessages = conversation['messages'];
          if (rawMessages is! List) continue;
          Map<String, dynamic>? completed;
          for (final raw in rawMessages) {
            if (raw is Map && (raw['id'] ?? '').toString() == entry.key) {
              completed = Map<String, dynamic>.from(raw);
              break;
            }
          }
          final content = completed?['content']?.toString() ?? '';
          if (completed == null || content.trim().isEmpty) continue;

          final local = ConversationService.instance;
          final matchingMessages = local
              .getMessages(entry.value)
              .where((item) => item.id == entry.key)
              .toList();
          final message = matchingMessages.isEmpty
              ? null
              : matchingMessages.first;
          if (message != null) {
            message.sourcesJson = (completed['sourcesJson'] ?? '').toString();
            message.isTruncated = completed['isTruncated'] == true;
            await local.updateMessageContent(message, content, sync: false);
          } else {
            await local.addMessage(
              Message(
                id: entry.key,
                role: 'assistant',
                content: content,
                conversationId: entry.value,
                timestamp: _parseDate(completed['timestamp']),
                sourcesJson: (completed['sourcesJson'] ?? '').toString(),
                isTruncated: completed['isTruncated'] == true,
              ),
              sync: false,
            );
          }
          pending.remove(entry.key);
        } catch (e) {
          debugPrint('pending generation sync ${entry.key}: $e');
        }
      }
      await _writePendingGenerations(pending);
    } finally {
      _syncingPendingGenerations = false;
    }
  }

  /// Envia uma conversa específica (após mensagem / rename / pin).
  Future<String?> pushConversation(
    String id, {
    bool reportFailure = false,
  }) async {
    if (!await _hasGoogleSession()) {
      if (reportFailure) {
        throw StateError('Sessão expirou durante a sincronização');
      }
      return null;
    }
    final local = ConversationService.instance;
    if (!local.conversationHasMessages(id)) return null;

    final conv = local.conversationById(id);
    if (conv == null) return null;

    final messages = local.getMessages(id);
    try {
      final res = await _client().put(
        '/conversations/$id',
        data: {
          'id': conv.id,
          'title': conv.title,
          'isPinned': conv.isPinned,
          'mode': conv.mode,
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
                'isTruncated': m.isTruncated,
                'sourcesJson': m.sourcesJson,
              },
          ],
        },
      );
      final status = res.statusCode ?? 0;
      if (status < 200 || status >= 300) {
        throw StateError('Falha ao enviar conversa $id: HTTP $status');
      }
      final payload = res.data;
      final revision = payload is Map && payload['conversation'] is Map
          ? (payload['conversation']['syncRevision'] ?? '').toString()
          : '';
      return revision.isEmpty ? null : revision;
    } catch (e, stack) {
      logSwallowed(e, stack, context: 'enviar conversa $id');
      if (reportFailure) rethrow;
      return null;
    }
  }

  /// Envia só a mensagem que mudou; evita reenviar o histórico em cada turno.
  Future<void> pushMessage(Message message) async {
    if (!await _hasGoogleSession()) return;
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
    if (!await _hasGoogleSession()) return;
    final conv = ConversationService.instance.conversationById(id);
    if (conv == null) return;
    try {
      final res = await _client().patch(
        '/conversations/$id',
        data: {
          'title': conv.title,
          'isPinned': conv.isPinned,
          'updatedAt': conv.updatedAt.toUtc().toIso8601String(),
          'mode': conv.mode,
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

  /// Guarda exclusões até o servidor confirmá-las. Se estiver offline,
  /// a próxima sincronização tentará novamente sem ressuscitar as mensagens.
  Future<void> deleteMessages(String conversationId, List<String> ids) async {
    if (conversationId.isEmpty || ids.isEmpty) return;
    if (IdentityService.instance.provider != 'google') return;
    await _withDeleteQueue(() async {
      final pending = await _readPendingMessageDeletes();
      pending.putIfAbsent(conversationId, () => <String>{}).addAll(ids);
      await _writePendingMessageDeletes(pending);
    });
    await _flushPendingMessageDeletes();
  }

  String get _pendingDeletesKey =>
      '$_pendingDeletesPrefix${IdentityService.instance.userId}';

  Future<Map<String, Set<String>>> _readPendingMessageDeletes() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_pendingDeletesKey);
    if (raw == null || raw.isEmpty) return <String, Set<String>>{};
    try {
      final json = jsonDecode(raw);
      if (json is! Map) return <String, Set<String>>{};
      return <String, Set<String>>{
        for (final entry in json.entries)
          if (entry.value is List)
            entry.key.toString(): (entry.value as List)
                .map((value) => value.toString())
                .where((value) => value.isNotEmpty)
                .toSet(),
      };
    } catch (error, stack) {
      logSwallowed(error, stack);
      return <String, Set<String>>{};
    }
  }

  Future<void> _writePendingMessageDeletes(
    Map<String, Set<String>> pending,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    pending.removeWhere((_, ids) => ids.isEmpty);
    if (pending.isEmpty) {
      await prefs.remove(_pendingDeletesKey);
    } else {
      await prefs.setString(
        _pendingDeletesKey,
        jsonEncode(pending.map((key, value) => MapEntry(key, value.toList()))),
      );
    }
  }

  /// Serializa alterações dos tombstones para duas exclusões simultâneas
  /// nunca sobrescreverem uma à outra no SharedPreferences.
  Future<void> _withDeleteQueue(Future<void> Function() action) {
    final task = _pendingDeleteQueue.then((_) => action());
    _pendingDeleteQueue = task.catchError((Object error, StackTrace stack) {
      logSwallowed(error, stack);
    });
    return task;
  }

  Future<void> _flushPendingMessageDeletes() async {
    if (!await _hasGoogleSession()) return;
    await _withDeleteQueue(() async {
      final pending = await _readPendingMessageDeletes();
      for (final entry in pending.entries.toList()) {
        final remaining = pending[entry.key];
        if (remaining == null || remaining.isEmpty) continue;
        // A API aceita até 500 IDs por chamada.
        while (remaining.isNotEmpty) {
          final batch = remaining.take(500).toList();
          try {
            final res = await _client().post(
              '/conversations/${Uri.encodeComponent(entry.key)}/messages/delete',
              data: {'ids': batch},
            );
            final status = res.statusCode ?? 0;
            if ((status < 200 || status >= 300) && status != 404) {
              debugPrint('pending deletes ${entry.key}: HTTP $status');
              break;
            }
            // 404: a conversa já não existe no servidor; não há mensagem
            // remota que precise ser excluída.
            remaining.removeAll(batch);
            await _writePendingMessageDeletes(pending);
          } catch (error, stack) {
            logSwallowed(error, stack);
            break;
          }
        }
      }
    });
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
    'isTruncated': m.isTruncated,
    'sourcesJson': m.sourcesJson,
  };

  Future<void> deleteRemote(String id) async {
    if (!await _hasGoogleSession()) return;
    try {
      await _client().delete('/conversations/$id');
    } catch (e) {
      debugPrint('delete remote conversation $id: $e');
    }
  }

  /// Busca mudanças em uma única requisição. O fallback é para instalações
  /// ainda usando a API da Fase 2: elas continuam sincronizando normalmente.
  Future<_RemoteSyncDelta> _pullRemoteChanges(Map<String, String> known) async {
    final response = await _client().post(
      '/conversations/sync/pull',
      data: {'known': known},
    );
    final status = response.statusCode ?? 0;
    if (status == 404 || status == 405) {
      return _pullRemoteChangesLegacy(known);
    }
    if (status < 200 || status >= 300 || response.data is! Map) {
      throw StateError('Falha na sincronização incremental: HTTP $status');
    }
    final body = Map<String, dynamic>.from(response.data as Map);
    final changed = parseRemoteConversations(status, body);
    final rawRevisions = body['revisions'];
    if (rawRevisions is! Map ||
        rawRevisions.values.any((value) => value is! String)) {
      throw const FormatException('Revisões ausentes na resposta da API');
    }
    return _RemoteSyncDelta(
      changed,
      rawRevisions.map(
        (key, value) => MapEntry(key.toString(), value.toString()),
      ),
    );
  }

  Future<_RemoteSyncDelta> _pullRemoteChangesLegacy(
    Map<String, String> known,
  ) async {
    final res = await _client().get(
      '/conversations',
      queryParameters: {'full': false},
    );
    final index = parseRemoteConversations(res.statusCode, res.data);
    final revisions = <String, String>{};
    final changed = <Map<String, dynamic>>[];
    for (final summary in index) {
      final id = (summary['id'] ?? '').toString();
      if (id.isEmpty) continue;
      final revision = (summary['syncRevision'] ?? '').toString();
      if (ConversationSyncPlanner.shouldDownload(
        revision: revision,
        lastSeenRevision: known[id],
        existsLocally: known.containsKey(id),
      )) {
        changed.add(await _pullSingleConversation(id));
      }
      if (revision.isNotEmpty) revisions[id] = revision;
    }
    return _RemoteSyncDelta(changed, revisions);
  }

  Future<Map<String, dynamic>> _pullSingleConversation(String id) async {
    final res = await _client().get(
      '/conversations/${Uri.encodeComponent(id)}',
    );
    final status = res.statusCode ?? 0;
    if (status < 200 || status >= 300 || res.data is! Map) {
      throw StateError('Falha ao baixar conversa $id: HTTP $status');
    }
    final result = Map<String, dynamic>.from(res.data as Map);
    if (result['id']?.toString() != id || result['messages'] is! List) {
      throw const FormatException('Conversa remota incompleta');
    }
    return result;
  }

  /// Testável sem login: falhas de HTTP ou respostas malformadas não podem
  /// ser tratadas como lista vazia (sincronização concluída com sucesso).
  static List<Map<String, dynamic>> parseRemoteConversations(
    int? statusCode,
    dynamic payload,
  ) {
    final code = statusCode ?? 0;
    if (code < 200 || code >= 300) {
      throw StateError('Falha ao receber conversas: HTTP $code');
    }
    if (payload is! Map) {
      throw const FormatException('Resposta de sincronização inválida');
    }
    final data = Map<String, dynamic>.from(payload);
    if (data['conversations'] is! List) {
      throw const FormatException('Lista de conversas ausente na resposta');
    }
    final list = data['conversations'] as List<dynamic>;
    if (list.any((item) => item is! Map)) {
      throw const FormatException('Conversa inválida no payload remoto');
    }
    return list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  Future<void> _mergeRemoteIntoLocal(List<Map<String, dynamic>> remote) async {
    final local = ConversationService.instance;
    final pendingDeletes = await _readPendingMessageDeletes();
    for (final r in remote) {
      final id = (r['id'] ?? '').toString();
      if (id.isEmpty) continue;

      final remoteUpdated = _parseDate(r['updatedAt'] ?? r['updated_at']);
      final existing = local.conversationById(id);
      final deletedIds = <String>{
        ...(r['deletedMessageIds'] as List<dynamic>? ?? const []).map(
          (value) => value.toString(),
        ),
        ...?pendingDeletes[id],
      };

      if (existing != null) {
        final locallyDeleted = local
            .getMessages(id)
            .where((message) => deletedIds.contains(message.id))
            .toList();
        if (locallyDeleted.isNotEmpty) {
          await local.deleteMessages(locallyDeleted, sync: false);
        }
        // Mesmo se o local for mais novo, importa mensagens novas de outros
        // aparelhos; os campos conflitantes são resolvidos pelo updatedAt.
      }

      final title = (r['title'] ?? 'Nova conversa').toString();
      final isPinned = r['isPinned'] == true || r['is_pinned'] == true;
      final mode = r['mode']?.toString();
      final createdAt = _parseDate(r['createdAt'] ?? r['created_at']);
      final messagesRaw = r['messages'] as List<dynamic>? ?? [];

      await local.applyRemoteConversation(
        id: id,
        title: title,
        isPinned: isPinned,
        mode: mode,
        modeProvided: r.containsKey('mode'),
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
                isTruncated: raw['isTruncated'] == true,
                sourcesJson: (raw['sourcesJson'] ?? '').toString(),
              ),
        ],
      );
    }
  }

  Future<Map<String, String>> _pushChangedLocalToRemote(
    Map<String, String> previouslyUploaded,
    Map<String, String> revisions,
  ) async {
    final local = ConversationService.instance;
    final all = [...local.pinnedConversations, ...local.recentConversations];
    final uploaded = <String, String>{};
    for (final conv in all) {
      final messages = local.getMessages(conv.id);
      if (messages.isEmpty) continue;
      final digest = ConversationSyncPlanner.snapshotHash(
        id: conv.id,
        title: conv.title,
        isPinned: conv.isPinned,
        mode: conv.mode,
        updatedAt: conv.updatedAt.toUtc().toIso8601String(),
        messages: [for (final msg in messages) _messagePayload(msg)],
      );
      if (ConversationSyncPlanner.shouldUpload(
        snapshot: digest,
        lastUploadedSnapshot: previouslyUploaded[conv.id],
      )) {
        // Esta operação continua usando o merge por ID + tombstones
        // implementado na Fase 1; uma falha cancela o checkpoint.
        final revision = await pushConversation(conv.id, reportFailure: true);
        if (revision != null) revisions[conv.id] = revision;
      }
      uploaded[conv.id] = digest;
    }
    return uploaded;
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
    } catch (error, stack) {
      logSwallowed(error, stack);
      return DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    }
  }
}

class _RemoteSyncDelta {
  final List<Map<String, dynamic>> changed;
  final Map<String, String> revisions;
  const _RemoteSyncDelta(this.changed, this.revisions);
}
