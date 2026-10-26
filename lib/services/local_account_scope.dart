import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'identity_service.dart';

/// Namespace local de dados. Nunca usa e-mail como nome de arquivo ou chave.
///
/// A migração automática das caixas legadas `conversations`/`messages` foi
/// intencionalmente desabilitada: elas não registravam o proprietário, logo
/// atribuí-las à próxima pessoa que fizer login poderia revelar dados alheios.
/// O histórico que já estiver no Railway será sincronizado normalmente.
class LocalAccountScope {
  const LocalAccountScope._(this.key);

  final String key;

  static LocalAccountScope fromSession({
    required bool loggedIn,
    required String provider,
    required String userId,
  }) {
    if (!loggedIn || userId == 'default' || userId.trim().isEmpty) {
      return const LocalAccountScope._('signed_out');
    }
    if (provider != 'google' && provider != 'guest') {
      return const LocalAccountScope._('signed_out');
    }
    final digest = sha256.convert(utf8.encode('$provider:$userId')).toString();
    return LocalAccountScope._('${provider}_${digest.substring(0, 32)}');
  }

  factory LocalAccountScope.current() {
    final identity = IdentityService.instance;
    return fromSession(
      loggedIn: identity.isLoggedIn,
      provider: identity.provider,
      userId: identity.userId,
    );
  }

  String get conversationsBox => 'gama_conversations_$key';
  String get messagesBox => 'gama_messages_$key';
  String get draftPrefix => 'gama_chat_draft_v2_${key}_';
  String get libraryPrefsKey => 'gama_library_v2_$key';
  String get libraryDirectoryName => 'gama_library_v2_$key';
  String get internalDownloadsDirectoryName => 'GamaDownloads_$key';
  String get pendingGenerationsPrefsKey => 'gama_pending_generations_v2_$key';
  String get remindersPrefsKey => 'gama_local_reminders_v2_$key';
  String get feedbackPrefix => 'gama_message_feedback_v2_${key}_';
}
