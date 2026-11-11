import 'package:flutter_test/flutter_test.dart';
import 'package:gama/models/conversation.dart';
import 'package:gama/models/message.dart';
import 'package:gama/utils/chat_history_window.dart';
import 'package:gama/utils/chat_message_presentation.dart';
import 'package:gama/utils/conversation_history_rows.dart';

Conversation _conversation(String id, DateTime updatedAt) => Conversation(
  id: id,
  title: 'Conversa $id',
  updatedAt: updatedAt,
);

Message _message(String id, DateTime timestamp, {String role = 'user'}) =>
    Message(
      id: id,
      conversationId: 'teste',
      role: role,
      content: 'Mensagem $id',
      timestamp: timestamp,
    );

void main() {
  group('Fase 6: projeção do histórico lateral', () {
    test('agrupa por dia local e mantém fixadas primeiro', () {
      final today = DateTime(2026, 11, 11, 14);
      final pinned = _conversation('pinned', today);
      final rows = buildConversationHistoryRows(
        pinned: [pinned],
        recent: [
          _conversation('hoje', DateTime(2026, 11, 11, 8)),
          _conversation('ontem', DateTime(2026, 11, 10, 22)),
          _conversation('semana', DateTime(2026, 11, 7, 12)),
          _conversation('antiga', DateTime(2026, 10, 20, 12)),
        ],
        now: today,
      );
      expect(rows.where((row) => row.isSection).map((row) => row.sectionTitle), [
        'Fixados', 'Hoje', 'Ontem', 'Últimos 7 dias', 'Mais antigas',
      ]);
      expect(rows.where((row) => !row.isSection).map((row) => row.conversation!.id), [
        'pinned', 'hoje', 'ontem', 'semana', 'antiga',
      ]);
    });

    test('não duplica IDs mesmo se aparecerem em duas categorias', () {
      final date = DateTime(2026, 11, 11);
      final duplicate = _conversation('id', date);
      final rows = buildConversationHistoryRows(
        pinned: [duplicate, duplicate],
        recent: [duplicate, _conversation('outro', date)],
        now: date,
      );
      expect(
        rows.where((row) => row.conversation != null).map((row) => row.conversation!.id),
        ['id', 'outro'],
      );
    });

    test('prepara milhares de itens sem gerar widgets fora da viewport', () {
      final now = DateTime(2026, 11, 11);
      final entries = List.generate(2500, (i) => _conversation('id-$i', now));
      final rows = buildConversationHistoryRows(pinned: const [], recent: entries, now: now);
      expect(rows.length, 2501); // Um título + 2.500 conversas.
      expect(rows.first.sectionTitle, 'Hoje');
      expect(rows.last.conversation!.id, 'id-2499');
    });
  });

  group('Fase 6: apresentação do histórico do chat', () {
    final timestamps = [
      DateTime(2026, 11, 9, 22),
      DateTime(2026, 11, 10, 7),
      DateTime(2026, 11, 10, 11),
      DateTime(2026, 11, 11, 8),
      DateTime(2026, 11, 11, 9),
    ];
    final messages = List.generate(
      5,
      (i) => _message('$i', timestamps[i], role: i.isOdd ? 'assistant' : 'user'),
    );

    test('preserva índices reais ao carregar mensagens anteriores', () {
      final window = ChatHistoryWindow(initialSize: 2, pageSize: 2);
      var view = ChatMessagePresentation(messages: messages, window: window);
      expect(view.hasOlder, isTrue);
      expect(view.olderCount, 3);
      expect(view.itemCount, 3);
      expect(view.isLoadEarlierRow(0), isTrue);
      expect(view.messageIndexForRow(1), 3);
      expect(view.messageIndexForRow(2), 4);
      expect(view.lastAssistantIndex, 3);

      window.loadEarlier(messages.length);
      view = ChatMessagePresentation(messages: messages, window: window);
      expect(view.olderCount, 1);
      expect(view.messageIndexForRow(1), 1);
      expect(view.messageIndexForRow(4), 4);

      window.loadEarlier(messages.length);
      view = ChatMessagePresentation(messages: messages, window: window);
      expect(view.hasOlder, isFalse);
      expect(view.itemCount, 5);
      expect(view.messageIndexForRow(0), 0);
      expect(view.messageIndexForRow(4), 4);
    });

    test('separador do primeiro item e apenas nas mudanças de dia', () {
      final view = ChatMessagePresentation(
        messages: messages,
        window: ChatHistoryWindow(initialSize: 5),
      );
      expect(
        List.generate(5, view.startsDayAt),
        [true, true, false, true, false],
      );
      final limited = ChatMessagePresentation(
        messages: messages,
        window: ChatHistoryWindow(initialSize: 2),
      );
      expect(limited.startsDayAt(3), isTrue);
      expect(limited.startsDayAt(4), isFalse);
    });
  });
}
