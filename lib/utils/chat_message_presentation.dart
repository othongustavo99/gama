import '../models/message.dart';
import 'chat_history_window.dart';
import 'local_calendar.dart';

/// Índices de apresentação do chat, separados das ações e do armazenamento.
/// Nunca remove mensagens nem altera índices no Hive/serviço de conversas.
class ChatMessagePresentation {
  ChatMessagePresentation({
    required List<Message> messages,
    required ChatHistoryWindow window,
  }) : _messages = messages,
       firstVisibleIndex = window.start(messages.length),
       olderCount = window.remaining(messages.length),
       itemCount = window.listLength(messages.length),
       lastAssistantIndex = messages.lastIndexWhere((m) => m.isAssistant);

  final List<Message> _messages;
  final int firstVisibleIndex;
  final int olderCount;
  final int itemCount;
  final int lastAssistantIndex;

  bool get hasOlder => olderCount > 0;

  bool isLoadEarlierRow(int rowIndex) => hasOlder && rowIndex == 0;

  /// O cabeçalho de carregamento, quando presente, não corresponde a mensagem.
  int messageIndexForRow(int rowIndex) {
    assert(rowIndex >= 0 && rowIndex < itemCount);
    assert(!isLoadEarlierRow(rowIndex));
    return firstVisibleIndex + rowIndex - (hasOlder ? 1 : 0);
  }

  bool startsDayAt(int messageIndex) {
    if (messageIndex == firstVisibleIndex) return true;
    if (messageIndex <= 0 || messageIndex >= _messages.length) return false;
    return localDaysAgo(
          _messages[messageIndex].timestamp,
          _messages[messageIndex - 1].timestamp,
        ) !=
        0;
  }
}
