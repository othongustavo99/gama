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

  List<Conversation> get pinnedConversations {
    return _conversationsBox.values
        .where((c) => c.isPinned)
        .toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  }

  List<Conversation> get recentConversations {
    return _conversationsBox.values
        .where((c) => !c.isPinned)
        .toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  }

  Conversation? get currentConversation {
    if (_currentConversationId == null) return null;
    return _conversationsBox.get(_currentConversationId);
  }

  Future<Conversation> createConversation({String title = 'Nova conversa'}) async {
    final id = const Uuid().v4();
    final conversation = Conversation(
      id: id,
      title: title,
    );

    await _conversationsBox.put(id, conversation);
    _currentConversationId = id;
    notifyListeners();
    return conversation;
  }

  Future<void> selectConversation(String id) async {
    _currentConversationId = id;
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