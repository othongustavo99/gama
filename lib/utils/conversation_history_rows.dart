import '../models/conversation.dart';
import 'local_calendar.dart';

/// Representação leve da lista do histórico. É construída uma vez por
/// atualização do histórico, enquanto a ListView.builder monta apenas as
/// linhas que cabem na tela (inclusive para históricos extensos).
class ConversationHistoryRow {
  const ConversationHistoryRow.section(String title)
    : sectionTitle = title,
      conversation = null;

  const ConversationHistoryRow.conversation(Conversation value)
    : conversation = value,
      sectionTitle = null;

  final String? sectionTitle;
  final Conversation? conversation;

  bool get isSection => sectionTitle != null;
}

/// Mantém a ordem definida pelo ConversationService: fixadas primeiro e,
/// depois, as conversas recentes nos grupos de calendário locais.
/// IDs repetidos são apresentados apenas uma vez.
List<ConversationHistoryRow> buildConversationHistoryRows({
  required List<Conversation> pinned,
  required List<Conversation> recent,
  DateTime? now,
}) {
  final rows = <ConversationHistoryRow>[];
  final seenIds = <String>{};
  final currentDate = now ?? DateTime.now();

  final uniquePinned = pinned.where((c) => seenIds.add(c.id)).toList();
  if (uniquePinned.isNotEmpty) {
    rows.add(const ConversationHistoryRow.section('Fixados'));
    rows.addAll(uniquePinned.map(ConversationHistoryRow.conversation));
  }

  final groups = <String, List<Conversation>>{
    'Hoje': [],
    'Ontem': [],
    'Últimos 7 dias': [],
    'Mais antigas': [],
  };
  for (final conversation in recent) {
    if (!seenIds.add(conversation.id)) continue;
    final days = localDaysAgo(conversation.updatedAt, currentDate);
    final title = days <= 0
        ? 'Hoje'
        : days == 1
            ? 'Ontem'
            : days <= 7
                ? 'Últimos 7 dias'
                : 'Mais antigas';
    groups[title]!.add(conversation);
  }

  for (final entry in groups.entries) {
    if (entry.value.isEmpty) continue;
    rows.add(ConversationHistoryRow.section(entry.key));
    rows.addAll(entry.value.map(ConversationHistoryRow.conversation));
  }
  return rows;
}
