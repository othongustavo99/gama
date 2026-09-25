import 'package:flutter/material.dart';

import '../models/conversation.dart';
import '../services/conversation_service.dart';
import '../screens/settings_screen.dart';

class AppDrawer extends StatelessWidget {
  final VoidCallback onNewChat;
  final Function(String conversationId) onSelectConversation;
  final VoidCallback? onOpenImages;
  final VoidCallback? onOpenLibrary;
  final VoidCallback? onOpenProjects;
  final VoidCallback? onOpenScheduled;
  final VoidCallback? onOpenPlugins;

  const AppDrawer({
    super.key,
    required this.onNewChat,
    required this.onSelectConversation,
    this.onOpenImages,
    this.onOpenLibrary,
    this.onOpenProjects,
    this.onOpenScheduled,
    this.onOpenPlugins,
  });

  @override
  Widget build(BuildContext context) {
    final service = ConversationService.instance;

    return Drawer(
      backgroundColor: const Color(0xFF171717),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ===== HEADER =====
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 12, 8),
              child: Row(
                children: [
                  const Text(
                    'Gamma',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.search, color: Colors.white70),
                    onPressed: () {
                      // TODO: busca de conversas
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Busca em breve')),
                      );
                    },
                  ),
                  IconButton(
                    icon: const Icon(Icons.edit_square, color: Colors.white70),
                    tooltip: 'Nova conversa',
                    onPressed: onNewChat,
                  ),
                ],
              ),
            ),

            const SizedBox(height: 8),

            // ===== MENU PRINCIPAL =====
            _DrawerItem(
              icon: Icons.image_outlined,
              label: 'Imagens',
              onTap: onOpenImages ?? () => _comingSoon(context),
            ),
            _DrawerItem(
              icon: Icons.menu_book_outlined,
              label: 'Biblioteca',
              onTap: onOpenLibrary ?? () => _comingSoon(context),
            ),
            _DrawerItem(
              icon: Icons.folder_outlined,
              label: 'Projetos',
              onTap: onOpenProjects ?? () => _comingSoon(context),
            ),
            _DrawerItem(
              icon: Icons.schedule_outlined,
              label: 'Agendado',
              onTap: onOpenScheduled ?? () => _comingSoon(context),
            ),
            _DrawerItem(
              icon: Icons.extension_outlined,
              label: 'Plugins',
              onTap: onOpenPlugins ?? () => _comingSoon(context),
            ),

            const SizedBox(height: 16),
            const Divider(color: Colors.white12, height: 1),

            // ===== FIXADOS =====
            Expanded(
              child: ListenableBuilder(
                listenable: service,
                builder: (context, _) {
                  final pinned = service.pinnedConversations;
                  final recent = service.recentConversations;

                  return ListView(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    children: [
                      if (pinned.isNotEmpty) ...[
                        const Padding(
                          padding: EdgeInsets.fromLTRB(16, 12, 16, 6),
                          child: Text(
                            'Fixados',
                            style: TextStyle(
                              color: Colors.white54,
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                        ...pinned.map(
                          (c) => _ConversationTile(
                            conversation: c,
                            isSelected: c.id == service.currentConversationId,
                            onTap: () => onSelectConversation(c.id),
                            onPin: () => service.togglePin(c.id),
                            onDelete: () => _confirmDelete(context, c),
                            onRename: () => _renameDialog(context, c),
                          ),
                        ),
                      ],

                      // ===== RECENTES =====
                      const Padding(
                        padding: EdgeInsets.fromLTRB(16, 12, 16, 6),
                        child: Text(
                          'Recentes',
                          style: TextStyle(
                            color: Colors.white54,
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      if (recent.isEmpty)
                        const Padding(
                          padding: EdgeInsets.all(16),
                          child: Text(
                            'Nenhuma conversa ainda',
                            style: TextStyle(color: Colors.white38),
                          ),
                        )
                      else
                        ...recent.map(
                          (c) => _ConversationTile(
                            conversation: c,
                            isSelected: c.id == service.currentConversationId,
                            onTap: () => onSelectConversation(c.id),
                            onPin: () => service.togglePin(c.id),
                            onDelete: () => _confirmDelete(context, c),
                            onRename: () => _renameDialog(context, c),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),

            // ===== BOTTOM =====
            const Divider(color: Colors.white12, height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: onNewChat,
                      icon: const Icon(Icons.edit_square, size: 18),
                      label: const Text('Chat'),
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFFFF6B00),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(24),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const SettingsScreen(),
                        ),
                      );
                    },
                    icon: const Icon(
                      Icons.settings_outlined,
                      color: Colors.white70,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _comingSoon(BuildContext context) {
    Navigator.pop(context); // fecha o drawer
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Em breve')));
  }

  Future<void> _confirmDelete(BuildContext context, Conversation c) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF2A2A2A),
        title: const Text(
          'Apagar conversa?',
          style: TextStyle(color: Colors.white),
        ),
        content: Text(
          '“${c.title}” será apagada permanentemente.',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'Apagar',
              style: TextStyle(color: Colors.redAccent),
            ),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await ConversationService.instance.deleteConversation(c.id);
    }
  }

  Future<void> _renameDialog(BuildContext context, Conversation c) async {
    final controller = TextEditingController(text: c.title);

    final newTitle = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF2A2A2A),
        title: const Text(
          'Renomear conversa',
          style: TextStyle(color: Colors.white),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            hintText: 'Título da conversa',
            hintStyle: TextStyle(color: Colors.white38),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Salvar'),
          ),
        ],
      ),
    );

    if (newTitle != null) {
      await ConversationService.instance.renameConversation(c.id, newTitle);
    }
  }
}

// ==================== WIDGETS AUXILIARES ====================

class _DrawerItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _DrawerItem({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: Colors.white70, size: 22),
      title: Text(
        label,
        style: const TextStyle(color: Colors.white, fontSize: 15),
      ),
      onTap: onTap,
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
    );
  }
}

class _ConversationTile extends StatelessWidget {
  final Conversation conversation;
  final bool isSelected;
  final VoidCallback onTap;
  final VoidCallback onPin;
  final VoidCallback onDelete;
  final VoidCallback onRename;

  const _ConversationTile({
    required this.conversation,
    required this.isSelected,
    required this.onTap,
    required this.onPin,
    required this.onDelete,
    required this.onRename,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: isSelected ? Colors.white.withOpacity(0.08) : Colors.transparent,
      child: ListTile(
        title: Text(
          conversation.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: isSelected ? Colors.white : Colors.white70,
            fontSize: 14,
          ),
        ),
        onTap: onTap,
        dense: true,
        contentPadding: const EdgeInsets.only(left: 16, right: 4),
        trailing: PopupMenuButton<String>(
          icon: const Icon(Icons.more_horiz, color: Colors.white38, size: 20),
          color: const Color(0xFF2A2A2A),
          onSelected: (value) {
            if (value == 'pin') onPin();
            if (value == 'rename') onRename();
            if (value == 'delete') onDelete();
          },
          itemBuilder: (context) => [
            PopupMenuItem(
              value: 'pin',
              child: Text(conversation.isPinned ? 'Desafixar' : 'Fixar'),
            ),
            const PopupMenuItem(value: 'rename', child: Text('Renomear')),
            const PopupMenuItem(
              value: 'delete',
              child: Text('Apagar', style: TextStyle(color: Colors.redAccent)),
            ),
          ],
        ),
      ),
    );
  }
}
