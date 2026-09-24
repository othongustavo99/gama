import 'package:hive/hive.dart';

part 'message.g.dart';

@HiveType(typeId: 0)
class Message extends HiveObject {
  @HiveField(0)
  final String id;

  @HiveField(1)
  final String role; // "user" | "assistant" | "system"

  @HiveField(2)
  String content; // <-- agora é mutável

  @HiveField(3)
  final DateTime timestamp;

  Message({
    required this.id,
    required this.role,
    required this.content,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  bool get isUser => role == 'user';
  bool get isAssistant => role == 'assistant';

  Map<String, dynamic> toJson() => {'role': role, 'content': content};
}
