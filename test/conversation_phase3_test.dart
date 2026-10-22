import 'package:flutter_test/flutter_test.dart';
import 'package:gama/utils/conversation_sync_planner.dart';

void main() {
  group('Fase 3: manifest e snapshots', () {
    test('servidor legado sempre baixa; revisões iguais não baixam', () {
      expect(
        ConversationSyncPlanner.shouldDownload(
          revision: null,
          lastSeenRevision: 'abc',
          existsLocally: true,
        ),
        isTrue,
      );
      expect(
        ConversationSyncPlanner.shouldDownload(
          revision: 'abc',
          lastSeenRevision: 'abc',
          existsLocally: true,
        ),
        isFalse,
      );
      expect(
        ConversationSyncPlanner.shouldDownload(
          revision: 'abc',
          lastSeenRevision: 'abc',
          existsLocally: false,
        ),
        isTrue,
      );
      expect(
        ConversationSyncPlanner.shouldDownload(
          revision: 'nova',
          lastSeenRevision: 'abc',
          existsLocally: true,
        ),
        isTrue,
      );
    });

    test('mudança de conteúdo com mesmo tamanho altera hash', () {
      String hash(String content) => ConversationSyncPlanner.snapshotHash(
        id: 'c',
        title: 'Conversa',
        isPinned: false,
        mode: null,
        updatedAt: '2026-10-22T12:00:00Z',
        messages: [
          {'id': 'm1', 'content': content, 'role': 'assistant'},
        ],
      );
      final original = hash('olá');
      expect(hash('ola'), isNot(original));
      expect(
        ConversationSyncPlanner.shouldUpload(
          snapshot: original,
          lastUploadedSnapshot: original,
        ),
        isFalse,
      );
      expect(
        ConversationSyncPlanner.shouldUpload(
          snapshot: hash('nova'),
          lastUploadedSnapshot: original,
        ),
        isTrue,
      );
    });
  });
}
