import 'package:hive/hive.dart';

part 'message.g.dart';

@HiveType(typeId: 0)
class Message extends HiveObject {
  @HiveField(0)
  final String id;

  @HiveField(1)
  final String role;

  @HiveField(2)
  String content;

  @HiveField(3)
  final DateTime timestamp;

  @HiveField(4)
  final String conversationId;

  Message({
    required this.id,
    required this.role,
    required this.content,
    required this.conversationId,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  bool get isUser => role == 'user';
  bool get isAssistant => role == 'assistant';

  Map<String, dynamic> toJson() => {
        'role': role,
        'content': content,
      };
}