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
      backgroundColor: GamaColors.background,
      appBar: AppBar(
        backgroundColor: GamaColors.surface,
        title: const Text('Projetos'),
      ),
      body: ListenableBuilder(
        listenable: service,
        builder: (context, _) {
          final pinned = service.pinnedConversations;
          if (pinned.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(28),
                child: Text(
                  'Nenhum projeto ainda.\n'
                  'Fixe uma conversa no menu ⋮ do drawer para aparecer aqui.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: GamaColors.textMuted, height: 1.4),
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
              return Material(
                color: GamaColors.surfaceCard,
                borderRadius: BorderRadius.circular(14),
                child: ListTile(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  leading: const Icon(
                    Icons.push_pin_rounded,
                    color: GamaColors.accent,
                  ),
                  title: Text(
                    c.title,
                    style: const TextStyle(color: GamaColors.textPrimary),
                  ),
                  trailing: const Icon(
                    Icons.chevron_right_rounded,
                    color: GamaColors.textMuted,
                  ),
                  onTap: () async {
                    await service.selectConversation(c.id);
                    if (context.mounted) Navigator.pop(context);
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
