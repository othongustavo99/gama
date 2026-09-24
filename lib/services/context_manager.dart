import '../models/message.dart';

class ContextManager {
  /// Maximum number of recent messages sent to the model.
  ///
  /// This is intentionally kept relatively small for local models.
  static const int maxRecentMessages = 30;

  /// Builds the conversation context that will be sent to Ollama.
  ///
  /// The Hive database can contain the complete conversation history,
  /// but the model does not need to receive everything on every request.
  List<Message> buildContext(List<Message> messages) {
    if (messages.length <= maxRecentMessages) {
      return List<Message>.from(messages);
    }

    return messages.sublist(messages.length - maxRecentMessages);
  }
}
