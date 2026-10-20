import '../models/message.dart';

class ContextManager {
  /// Maximum number of recent messages sent to the model.
  ///
  /// The complete conversation stays safely in Hive; this limit only controls
  /// how much history is sent over the network on each request.
  static const int maxRecentMessages = 30;

  /// Avoids sending an orphan assistant message as the first item of a
  /// trimmed context. This keeps the recent window more coherent.
  List<Message> buildContext(List<Message> messages) {
    if (messages.length <= maxRecentMessages) {
      return List<Message>.from(messages);
    }

    var start = messages.length - maxRecentMessages;

    // If trimming starts in the middle of a user/assistant exchange, prefer
    // starting at the next user message when possible.
    while (start < messages.length - 1 && messages[start].isAssistant) {
      start++;
    }

    return List<Message>.from(messages.sublist(start));
  }
}
