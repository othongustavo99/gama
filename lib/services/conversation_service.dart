import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:uuid/uuid.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/conversation.dart';
import '../models/message.dart';
import 'conversation_sync_service.dart';

class ConversationService extends ChangeNotifier {
  ConversationService._();
  static final ConversationService instance = ConversationService._();

  late Box<Conversation> _conversationsBox;
  late Box<Message> _messagesBox;

  String? _currentConversationId;
  final Map<String, String> _drafts = <String, String>{};
  final Set<String> _pendingConversationDeletes = <String>{};
  final Map<String, Timer> _conversationDeleteTimers = <String, Timer>{};
  static const _draftPrefix = 'gama_chat_draft_';

  String? get currentConversationId => _currentConversationId;

  String? draftFor(String id) => _drafts[id];

  Future<void> saveDraft(String id, String value) async {
    if (value.isEmpty) {
      _drafts.remove(id);
    } else {
      _drafts[id] = value;
    }
    final prefs = await SharedPreferences.getInstance();
    final key = '$_draftPrefix$id';
    if (value.isEmpty) {
      await prefs.remove(key);
    } else {
      await prefs.setString(key, value);
    }
    notifyListeners();
  }

  Future<void> init() async {
    _conversationsBox = await Hive.openBox<Conversation>('conversations');
    _messagesBox = await Hive.openBox<Message>('messages');

    final prefs = await SharedPreferences.getInstance();
    for (final key in prefs.getKeys()) {
      if (!key.startsWith(_draftPrefix)) continue;
      final draft = prefs.getString(key);
      if (draft != null && draft.trim().isNotEmpty) {
        _drafts[key.substring(_draftPrefix.length)] = draft;
      }
    }

    // Remove TODOS os rascunhos vazios de sessões anteriores.
    await purgeEmptyConversations(exceptId: '');

    // Não seleciona conversa antiga aqui: o Home sempre abre uma nova.
    // Só cria se a box estiver totalmente vazia (primeiro uso).
    if (_conversationsBox.isEmpty) {
      await createConversation(title: 'Nova conversa');
    }
  }

  // ==================== CONVERSAS ====================

  /// True se a conversa já tem pelo menos uma mensagem persistida.
  bool conversationHasMessages(String id) {
    return _messagesBox.values.any((m) => m.conversationId == id);
  }

  /// Remove conversas sem mensagens.
  /// [exceptId] preservada (passe string vazia ou null para apagar todas as vazias).
  Future<void> purgeEmptyConversations({String? exceptId}) async {
    final empties = _conversationsBox.values
        .where(
          (c) =>
              c.id != exceptId &&
              !conversationHasMessages(c.id) &&
              (_drafts[c.id]?.trim().isNotEmpty ?? false) == false,
        )
        .toList();
    if (empties.isEmpty) return;
    for (final c in empties) {
      await _conversationsBox.delete(c.id);
    }
    // Se a conversa atual era vazia e foi apagada, limpa o ponteiro.
    if (_currentConversationId != null &&
        !_conversationsBox.containsKey(_currentConversationId)) {
      _currentConversationId = null;
    }
    notifyListeners();
  }

  List<Conversation> get pinnedConversations {
    return _conversationsBox.values
        .where(
          (c) =>
              !_pendingConversationDeletes.contains(c.id) &&
              c.isPinned &&
              (conversationHasMessages(c.id) ||
                  (_drafts[c.id]?.isNotEmpty ?? false)),
        )
        .toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  }

  List<Conversation> get recentConversations {
    return _conversationsBox.values
        .where(
          (c) =>
              !_pendingConversationDeletes.contains(c.id) &&
              !c.isPinned &&
              (conversationHasMessages(c.id) ||
                  (_drafts[c.id]?.isNotEmpty ?? false)),
        )
        .toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  }

  Conversation? get currentConversation {
    if (_currentConversationId == null) return null;
    return _conversationsBox.get(_currentConversationId);
  }

  Conversation? conversationById(String id) => _conversationsBox.get(id);

  /// Aplica conversa vinda do Railway (merge remoto → local).
  Future<void> applyRemoteConversation({
    required String id,
    required String title,
    required bool isPinned,
    String? mode,
    required DateTime createdAt,
    required DateTime updatedAt,
    required List<Message> messages,
  }) async {
    final existing = _conversationsBox.get(id);
    if (existing == null) {
      final conv = Conversation(
        id: id,
        title: title,
        isPinned: isPinned,
        mode: mode,
        createdAt: createdAt,
        updatedAt: updatedAt,
      );
      await _conversationsBox.put(id, conv);
    } else {
      existing.title = title;
      existing.isPinned = isPinned;
      if (mode != null) existing.mode = mode;
      existing.updatedAt = updatedAt;
      await existing.save();
    }

    // Substitui mensagens locais desta conversa pelas do remoto
    final old = _messagesBox.values
        .where((m) => m.conversationId == id)
        .toList();
    for (final m in old) {
      await m.delete();
    }
    for (final m in messages) {
      if (m.id.isEmpty || m.content.trim().isEmpty) continue;
      await _messagesBox.add(m);
    }
    notifyListeners();
  }

  Future<Conversation> createConversation({
    String title = 'Nova conversa',
    String? mode,
  }) async {
    final id = const Uuid().v4();
    final conversation = Conversation(id: id, title: title, mode: mode);

    await _conversationsBox.put(id, conversation);
    _currentConversationId = id;
    notifyListeners();
    return conversation;
  }

  /// Cria uma conversa para uma rota independente, sem trocar a conversa que
  /// o HomeScreen está exibindo. Usado pelos modos da Oficina.
  Future<Conversation> createDetachedConversation({
    String title = 'Nova conversa',
    String? mode,
  }) async {
    final id = const Uuid().v4();
    final conversation = Conversation(id: id, title: title, mode: mode);
    await _conversationsBox.put(id, conversation);
    notifyListeners();
    return conversation;
  }

  /// Cria nova conversa apenas se a atual já tiver mensagens.
  /// Se a atual estiver vazia, reutiliza o rascunho (não gera outra vazia).
  Future<Conversation> createConversationIfNeeded({
    String title = 'Nova conversa',
    String? mode,
  }) async {
    final currentId = _currentConversationId;
    if (currentId != null &&
        !conversationHasMessages(currentId) &&
        (_drafts[currentId]?.trim().isNotEmpty ?? false) == false) {
      final existing = _conversationsBox.get(currentId);
      if (existing != null) {
        if (mode != null && existing.mode != mode) {
          existing.mode = mode;
          await existing.save();
          notifyListeners();
        }
        return existing;
      }
    }
    // Apaga outros rascunhos vazios e cria a nova
    await purgeEmptyConversations(exceptId: currentId);
    return createConversation(title: title, mode: mode);
  }

  /// Abre sempre uma conversa nova em branco (usado no boot do app).
  /// Rascunhos vazios anteriores são apagados; conversas com mensagem ficam.
  Future<Conversation> openFreshConversation() async {
    await purgeEmptyConversations(exceptId: '');
    return createConversation(title: 'Nova conversa');
  }

  Future<void> selectConversation(String id) async {
    final previousId = _currentConversationId;
    _currentConversationId = id;
    // Se saiu de um rascunho vazio, apaga para não acumular
    if (previousId != null &&
        previousId != id &&
        !conversationHasMessages(previousId) &&
        (_drafts[previousId]?.trim().isNotEmpty ?? false) == false) {
      await _conversationsBox.delete(previousId);
    }
    notifyListeners();
  }

  Future<void> renameConversation(String id, String newTitle) async {
    final conv = _conversationsBox.get(id);
    if (conv == null) return;
    conv.title = newTitle.trim().isEmpty ? 'Nova conversa' : newTitle.trim();
    conv.updatedAt = DateTime.now();
    await conv.save();
    notifyListeners();
    // ignore: unawaited_futures
    ConversationSyncService.instance.pushConversationMetadata(id);
  }

  Future<void> updateConversationMode(String id, String? mode) async {
    final conv = _conversationsBox.get(id);
    if (conv == null || conv.mode == mode) return;
    conv.mode = mode;
    conv.updatedAt = DateTime.now();
    await conv.save();
    notifyListeners();
    ConversationSyncService.instance.pushConversationMetadata(id);
  }

  Future<void> togglePin(String id) async {
    final conv = _conversationsBox.get(id);
    if (conv == null) return;
    conv.isPinned = !conv.isPinned;
    conv.updatedAt = DateTime.now();
    await conv.save();
    notifyListeners();
    // ignore: unawaited_futures
    ConversationSyncService.instance.pushConversationMetadata(id);
  }

  Future<void> deleteConversation(String id) async {
    _conversationDeleteTimers.remove(id)?.cancel();
    _pendingConversationDeletes.remove(id);
    // Apaga todas as mensagens dessa conversa
    final messagesToDelete = _messagesBox.values
        .where((m) => m.conversationId == id)
        .toList();

    for (final msg in messagesToDelete) {
      await msg.delete();
    }

    await _conversationsBox.delete(id);
    _drafts.remove(id);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_draftPrefix$id');

    // Se apagou a conversa atual, seleciona outra
    if (_currentConversationId == id) {
      if (_conversationsBox.isNotEmpty) {
        _currentConversationId = _conversationsBox.values
            .toList()
            .sortedByUpdated
            .first
            .id;
      } else {
        await createConversation();
      }
    }

    notifyListeners();
    // ignore: unawaited_futures
    ConversationSyncService.instance.deleteRemote(id);
  }

  void stageDeleteConversation(String id) {
    if (_conversationsBox.get(id) == null ||
        !_pendingConversationDeletes.add(id)) {
      return;
    }
    notifyListeners();
    _conversationDeleteTimers[id] = Timer(const Duration(seconds: 3), () {
      _conversationDeleteTimers.remove(id);
      // ignore: unawaited_futures
      deleteConversation(id);
    });
  }

  void undoDeleteConversation(String id) {
    _conversationDeleteTimers.remove(id)?.cancel();
    if (_pendingConversationDeletes.remove(id)) notifyListeners();
  }

  Future<void> touchConversation(String id) async {
    final conv = _conversationsBox.get(id);
    if (conv == null) return;
    conv.updatedAt = DateTime.now();
    await conv.save();
    notifyListeners();
  }

  // ==================== MENSAGENS ====================

  List<Message> getMessages(String conversationId) {
    return _messagesBox.values
        .where((m) => m.conversationId == conversationId)
        .toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
  }

  Future<void> addMessage(Message message, {bool sync = true}) async {
    message.ensureCurrentVariant();
    await _messagesBox.add(message);
    await touchConversation(message.conversationId);
    notifyListeners();
    if (sync) {
      // ignore: unawaited_futures
      ConversationSyncService.instance.pushMessage(message);
    }
  }

  /// Remove um conjunto de mensagens e sincroniza a conversa uma única vez.
  /// Usado por editar/reenviar e regenerar a última resposta.
  Future<void> deleteMessages(
    List<Message> messages, {
    bool sync = true,
  }) async {
    if (messages.isEmpty) return;
    final conversationIds = <String>{};
    final deletedIdsByConversation = <String, List<String>>{};
    for (final message in messages) {
      conversationIds.add(message.conversationId);
      deletedIdsByConversation
          .putIfAbsent(message.conversationId, () => <String>[])
          .add(message.id);
      try {
        if (message.isInBox) {
          await message.delete();
        }
      } catch (e) {
        debugPrint('Não foi possível remover a mensagem ${message.id}: $e');
      }
    }
    notifyListeners();
    if (sync) {
      for (final conversationId in conversationIds) {
        await ConversationSyncService.instance.deleteMessages(
          conversationId,
          deletedIdsByConversation[conversationId] ?? const <String>[],
        );
      }
    }
  }

  Future<void> updateMessageContent(
    Message message,
    String newContent, {
    bool sync = true,
  }) async {
    message.content = newContent;
    message.ensureCurrentVariant();
    await message.save();
    notifyListeners();
    if (sync) {
      // ignore: unawaited_futures
      ConversationSyncService.instance.pushMessage(message);
    }
  }
}

// Extensão só pra ordenar
extension on List<Conversation> {
  List<Conversation> get sortedByUpdated {
    final list = List<Conversation>.from(this);
    list.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return list;
  }
}
