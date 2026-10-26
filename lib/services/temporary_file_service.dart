import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'conversation_service.dart';
import 'local_account_scope.dart';
import '../utils/error_logger.dart';

/// Remove somente sobras conhecidas da Gama, nunca anexos do usuário,
/// Biblioteca, projetos, arquivos baixados ou outros arquivos temporários.
class TemporaryFileService {
  TemporaryFileService._();
  static final TemporaryFileService instance = TemporaryFileService._();

  static final _clipboardName = RegExp(r'^gama-clipboard-\d+\.png$');
  static final _partName = RegExp(r'^.+\.part-\d+$');

  Future<void> cleanupAbandonedFiles() async {
    if (kIsWeb) return;
    try {
      final now = DateTime.now();
      // Mais conservador para anexos colados: podem ser usados em rascunhos.
      await _cleanupDir(
        Directory.systemTemp,
        _clipboardName,
        now.subtract(const Duration(days: 60)),
        checkMessageReferences: true,
      );

      final docs = await getApplicationDocumentsDirectory();
      await _cleanupDir(
        Directory(p.join(docs.path, LocalAccountScope.current().internalDownloadsDirectoryName)),
        _partName,
        now.subtract(const Duration(days: 7)),
      );
      if (Platform.isAndroid) {
        final external = await getExternalStorageDirectory();
        if (external != null) {
          await _cleanupDir(
            Directory(p.join(external.path, 'Download', 'Gama')),
            _partName,
            now.subtract(const Duration(days: 7)),
          );
        }
      }
    } catch (error, stack) {
      // Otimização opcional nunca deve bloquear o app.
      logSwallowed(error, stack, context: 'limpeza de temporários');
    }
  }

  bool _isReferenced(String filePath) {
    final conversations = ConversationService.instance;
    for (final conv in [
      ...conversations.pinnedConversations,
      ...conversations.recentConversations,
    ]) {
      for (final message in conversations.getMessages(conv.id)) {
        if (message.content.contains(filePath) ||
            message.attachmentMetadataJson.contains(filePath)) {
          return true;
        }
      }
    }
    return false;
  }

  Future<void> _cleanupDir(
    Directory directory,
    RegExp filePattern,
    DateTime cutoff, {
    bool checkMessageReferences = false,
  }) async {
    if (!await directory.exists()) return;
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File || !filePattern.hasMatch(p.basename(entity.path))) {
        continue;
      }
      try {
        // Impede seguir symlinks ou tocar em diretórios não esperados.
        if (await FileSystemEntity.type(entity.path, followLinks: false) !=
            FileSystemEntityType.file) {
          continue;
        }
        final stat = await entity.stat();
        if (!stat.modified.isBefore(cutoff)) continue;
        if (checkMessageReferences && _isReferenced(entity.path)) continue;
        await entity.delete();
      } catch (error, stack) {
        logSwallowed(error, stack, context: 'arquivo temporário antigo');
      }
    }
  }
}
