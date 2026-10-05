import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:uuid/uuid.dart';

import '../models/conversation.dart';
import '../models/message.dart';
import 'conversation_sync_service.dart';

class ConversationService extends ChangeNotifier {
  ConversationService._();
  static final ConversationService instance = ConversationService._();

  late Box<Conversation> _conversationsBox;
  late Box<Message> _messagesBox;

  String? _currentConversationId;

  String? get currentConversationId => _currentConversationId;

  Future<void> init() async {
    _conversationsBox = await Hive.openBox<Conversation>('conversations');
    _messagesBox = await Hive.openBox<Message>('messages');

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
        .where((c) => c.id != exceptId && !conversationHasMessages(c.id))
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
    // Só lista conversas que já receberam mensagem (não mostra rascunhos vazios)
    return _conversationsBox.values
        .where((c) => c.isPinned && conversationHasMessages(c.id))
        .toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  }

  List<Conversation> get recentConversations {
    // Só lista conversas que já receberam mensagem (não mostra rascunhos vazios)
    return _conversationsBox.values
        .where((c) => !c.isPinned && conversationHasMessages(c.id))
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
        createdAt: createdAt,
        updatedAt: updatedAt,
      );
      await _conversationsBox.put(id, conv);
    } else {
      existing.title = title;
      existing.isPinned = isPinned;
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
  }) async {
    final id = const Uuid().v4();
    final conversation = Conversation(id: id, title: title);

    await _conversationsBox.put(id, conversation);
    _currentConversationId = id;
    notifyListeners();
    return conversation;
  }

  /// Cria nova conversa apenas se a atual já tiver mensagens.
  /// Se a atual estiver vazia, reutiliza o rascunho (não gera outra vazia).
  Future<Conversation> createConversationIfNeeded({
    String title = 'Nova conversa',
  }) async {
    final currentId = _currentConversationId;
    if (currentId != null && !conversationHasMessages(currentId)) {
      final existing = _conversationsBox.get(currentId);
      if (existing != null) return existing;
    }
    // Apaga outros rascunhos vazios e cria a nova
    await purgeEmptyConversations(exceptId: currentId);
    return createConversation(title: title);
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
        !conversationHasMessages(previousId)) {
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
    ConversationSyncService.instance.pushConversation(id);
  }

  Future<void> togglePin(String id) async {
    final conv = _conversationsBox.get(id);
    if (conv == null) return;
    conv.isPinned = !conv.isPinned;
    conv.updatedAt = DateTime.now();
    await conv.save();
    notifyListeners();
    // ignore: unawaited_futures
    ConversationSyncService.instance.pushConversation(id);
  }

  Future<void> deleteConversation(String id) async {
    // Apaga todas as mensagens dessa conversa
    final messagesToDelete = _messagesBox.values
        .where((m) => m.conversationId == id)
        .toList();

    for (final msg in messagesToDelete) {
      await msg.delete();
    }

    await _conversationsBox.delete(id);

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

  Future<void> addMessage(Message message) async {
    await _messagesBox.add(message);
    await touchConversation(message.conversationId);
    notifyListeners();
    // ignore: unawaited_futures
    ConversationSyncService.instance.pushConversation(message.conversationId);
  }

  Future<void> updateMessageContent(Message message, String newContent) async {
    message.content = newContent;
    await message.save();
    notifyListeners();
    // ignore: unawaited_futures
    ConversationSyncService.instance.pushConversation(message.conversationId);
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
