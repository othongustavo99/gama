import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Decisões puras da sincronização: úteis em testes, sem Hive ou rede.
class ConversationSyncPlanner {
  const ConversationSyncPlanner._();

  /// Sem token (servidor antigo), baixa normalmente por segurança.
  static bool shouldDownload({
    required String? revision,
    required String? lastSeenRevision,
    required bool existsLocally,
  }) {
    if (!existsLocally) return true;
    return revision == null || revision.isEmpty || revision != lastSeenRevision;
  }

  static bool shouldUpload({
    required String snapshot,
    required String? lastUploadedSnapshot,
  }) => snapshot != lastUploadedSnapshot;

  /// Hash do estado persistido, não da renderização ou do texto parcial.
  /// Inclui detalhes que podem mudar sem aumentar a contagem de mensagens.
  static String snapshotHash({
    required String id,
    required String title,
    required bool isPinned,
    required String? mode,
    required String updatedAt,
    required List<Map<String, dynamic>> messages,
  }) {
    final canonical = jsonEncode(<String, dynamic>{
      'id': id,
      'title': title,
      'isPinned': isPinned,
      'mode': mode,
      'updatedAt': updatedAt,
      'messages': messages,
    });
    return sha256.convert(utf8.encode(canonical)).toString();
  }
}
