import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:uuid/uuid.dart';

import '../models/conversation.dart';
import '../models/message.dart';

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

    // Remove conversas vazias antigas (exceto a mais recente, que pode ser o rascunho)
    await purgeEmptyConversations();

    // Se não existir nenhuma conversa, cria a primeira
    if (_conversationsBox.isEmpty) {
      await createConversation(title: 'Nova conversa');
    } else {
      _currentConversationId = _conversationsBox.values
          .toList()
          .sortedByUpdated
          .first
          .id;
    }
  }

  // ==================== CONVERSAS ====================

  /// True se a conversa já tem pelo menos uma mensagem persistida.
  bool conversationHasMessages(String id) {
    return _messagesBox.values.any((m) => m.conversationId == id);
  }

  /// Remove conversas sem mensagens. [exceptId] é preservada (rascunho atual).
  Future<void> purgeEmptyConversations({String? exceptId}) async {
    final keep = exceptId ?? _currentConversationId;
    final empties = _conversationsBox.values
        .where((c) => c.id != keep && !conversationHasMessages(c.id))
        .toList();
    if (empties.isEmpty) return;
    for (final c in empties) {
      await _conversationsBox.delete(c.id);
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
    // Sai de um rascunho vazio anterior (se houver outro) e cria a nova
    await purgeEmptyConversations(exceptId: null);
    return createConversation(title: title);
  }

  Future<void> selectConversation(String id) async {
    final previousId = _currentConversationId;
    _currentConversationId = id;
    // Se saiu de um rascunho vazio, apaga para não acumular na lista
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
  }

  Future<void> togglePin(String id) async {
    final conv = _conversationsBox.get(id);
    if (conv == null) return;
    conv.isPinned = !conv.isPinned;
    conv.updatedAt = DateTime.now();
    await conv.save();
    notifyListeners();
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
  }

  Future<void> updateMessageContent(Message message, String newContent) async {
    message.content = newContent;
    await message.save();
    notifyListeners();
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
