import 'package:flutter/material.dart';

import '../core/gama_colors.dart';
import '../services/conversation_service.dart';

/// Projetos = conversas fixadas / espaços de trabalho leves.
class ProjectsScreen extends StatelessWidget {
  const ProjectsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final service = ConversationService.instance;

    return Scaffold(
      backgroundColor: context.gama.background,
      appBar: AppBar(
        backgroundColor: context.gama.surface,
        title: const Text('Projetos'),
      ),
      body: ListenableBuilder(
        listenable: service,
        builder: (context, _) {
          final pinned = service.pinnedConversations;
          if (pinned.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      width: 64,
                      height: 64,
                      decoration: BoxDecoration(
                        color: context.gama.accentSoft,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Icon(
                        Icons.folder_special_rounded,
                        color: context.gama.accent,
                        size: 32,
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      'Nenhum projeto ainda',
                      style: TextStyle(
                        color: context.gama.textPrimary,
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Fixe uma conversa no menu ⋮ do histórico (drawer) '
                      'para ela aparecer aqui como espaço de trabalho.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: context.gama.textMuted,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: pinned.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (_, i) {
              final c = pinned[i];
              final updated = c.updatedAt;
              final dd = updated.day.toString().padLeft(2, '0');
              final mm = updated.month.toString().padLeft(2, '0');
              final hh = updated.hour.toString().padLeft(2, '0');
              final mi = updated.minute.toString().padLeft(2, '0');
              return Material(
                color: context.gama.surfaceCard,
                borderRadius: BorderRadius.circular(14),
                child: ListTile(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  leading: Icon(
                    Icons.push_pin_rounded,
                    color: context.gama.accent,
                  ),
                  title: Text(
                    c.title,
                    style: TextStyle(color: context.gama.textPrimary),
                  ),
                  subtitle: Text(
                    'Atualizado $dd/$mm $hh:$mi',
                    style: TextStyle(
                      color: context.gama.textMuted,
                      fontSize: 12,
                    ),
                  ),
                  trailing: Icon(
                    Icons.chevron_right_rounded,
                    color: context.gama.textMuted,
                  ),
                  onTap: () async {
                    await service.selectConversation(c.id);
                    if (context.mounted) Navigator.pop(context);
                  },
                  onLongPress: () async {
                    final confirm = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        backgroundColor: context.gama.surfaceCard,
                        title: Text(
                          'Desafixar projeto?',
                          style: TextStyle(color: context.gama.textPrimary),
                        ),
                        content: Text(
                          'A conversa "${c.title}" sai da lista de projetos, '
                          'mas continua no histórico.',
                          style: TextStyle(color: context.gama.textSecondary),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(ctx, false),
                            child: const Text('Cancelar'),
                          ),
                          TextButton(
                            onPressed: () => Navigator.pop(ctx, true),
                            child: const Text('Desafixar'),
                          ),
                        ],
                      ),
                    );
                    if (confirm == true) {
                      await service.togglePin(c.id);
                    }
                  },
                ),
              );
            },
          );
        },
      ),
    );
  }
}
