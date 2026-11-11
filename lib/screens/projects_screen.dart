import 'package:flutter/material.dart';

import '../core/gama_colors.dart';
import '../services/conversation_service.dart';
import '../widgets/gama_empty_panel.dart';
import '../widgets/gama_floating_page.dart';
import '../widgets/gama_section_intro.dart';

/// Visão detalhada do mesmo conjunto de conversas fixadas que aparece
/// no histórico. Ações permanecem disponíveis sem depender de long press.
class ProjectsScreen extends StatelessWidget {
  const ProjectsScreen({super.key});

  Future<void> _unpin(BuildContext context, String id, String title) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Desafixar conversa?'),
        content: Text('“$title” continuará no histórico de conversas.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Desafixar'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ConversationService.instance.togglePin(id);
  }

  @override
  Widget build(BuildContext context) {
    final service = ConversationService.instance;
    return Scaffold(
      backgroundColor: context.gama.background,
      body: GamaFloatingPage(
        contentBehindHeader: true,
        child: ListenableBuilder(
          listenable: service,
          builder: (context, _) {
            final pinned = service.pinnedConversations;
            return ListView(
              padding: EdgeInsets.fromLTRB(
                16, MediaQuery.paddingOf(context).top + 84, 16, 24),
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(8, 8, 8, 12),
                  child: GamaSectionIntro(
                    title: 'Conversas fixadas',
                    description: 'Suas conversas importantes, em um só lugar.',
                    icon: Icons.push_pin_outlined,
                  ),
                ),
                if (pinned.isEmpty)
                  const Padding(
                    padding: EdgeInsets.only(top: 52),
                    child: GamaEmptyPanel(
                      icon: Icons.push_pin_outlined,
                      title: 'Nenhuma conversa fixada',
                      description: 'No histórico, toque em Mais ações de uma '
                          'conversa e selecione Fixar.',
                    ),
                  )
                else
                  for (final conversation in pinned) ...[
                    Material(
                      color: context.gama.surfaceCard,
                      borderRadius: BorderRadius.circular(14),
                      child: Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: context.gama.borderSoft),
                        ),
                        child: ListTile(
                          leading: Icon(Icons.push_pin_rounded,
                              color: context.gama.accent, size: 19),
                          title: Text(conversation.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: context.gama.textPrimary)),
                          subtitle: Text(
                            'Atualizada em '
                            '${conversation.updatedAt.day.toString().padLeft(2, '0')}/'
                            '${conversation.updatedAt.month.toString().padLeft(2, '0')} '
                            '${conversation.updatedAt.hour.toString().padLeft(2, '0')}:'
                            '${conversation.updatedAt.minute.toString().padLeft(2, '0')}',
                            style: TextStyle(color: context.gama.textMuted,
                                fontSize: 12),
                          ),
                          trailing: IconButton(
                            tooltip: 'Desafixar conversa',
                            icon: const Icon(Icons.push_pin_outlined, size: 19),
                            onPressed: () => _unpin(context, conversation.id,
                                conversation.title),
                          ),
                          onTap: () async {
                            await service.selectConversation(conversation.id);
                            if (context.mounted) Navigator.of(context).pop();
                          },
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
              ],
            );
          },
        ),
      ),
    );
  }
}
