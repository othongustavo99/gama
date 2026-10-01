import 'package:flutter/material.dart';

import '../core/gama_colors.dart';
import '../models/conversation.dart';
import '../services/conversation_service.dart';
import '../services/identity_service.dart';
import '../services/auth_service.dart';
import '../screens/login_screen.dart';
import '../screens/settings_screen.dart';
import '../screens/images_screen.dart';
import '../screens/library_screen.dart';
import '../screens/projects_screen.dart';
import '../screens/scheduled_screen.dart';
import '../screens/plugins_screen.dart';

class AppDrawer extends StatelessWidget {
  final VoidCallback onNewChat;
  final Function(String conversationId) onSelectConversation;

  const AppDrawer({
    super.key,
    required this.onNewChat,
    required this.onSelectConversation,
  });

  @override
  Widget build(BuildContext context) {
    final service = ConversationService.instance;
    final identity = IdentityService.instance;

    return Drawer(
      backgroundColor: GamaColors.surfaceElevated,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 8, 12),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: GamaColors.accentSoft,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: GamaColors.accent.withOpacity(0.35),
                      ),
                    ),
                    alignment: Alignment.center,
                    clipBehavior: Clip.antiAlias,
                    child:
                        identity.photoUrl != null &&
                            identity.photoUrl!.isNotEmpty
                        ? Image.network(
                            identity.photoUrl!,
                            fit: BoxFit.cover,
                            width: 40,
                            height: 40,
                            errorBuilder: (_, __, ___) => const Text(
                              'G',
                              style: TextStyle(
                                color: GamaColors.accent,
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          )
                        : const Text(
                            'G',
                            style: TextStyle(
                              color: GamaColors.accent,
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          identity.displayName,
                          style: const TextStyle(
                            color: GamaColors.textPrimary,
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          identity.provider == 'google'
                              ? (identity.email ?? 'Conta Google')
                              : 'Gamma · convidado',
                          style: const TextStyle(
                            color: GamaColors.textMuted,
                            fontSize: 11,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const Divider(color: GamaColors.divider, height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
              child: Material(
                color: GamaColors.accent.withOpacity(0.12),
                borderRadius: BorderRadius.circular(12),
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () {
                    Navigator.pop(context);
                    onNewChat();
                  },
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    child: Row(
                      children: [
                        Icon(
                          Icons.edit_outlined,
                          color: GamaColors.accent,
                          size: 20,
                        ),
                        SizedBox(width: 10),
                        Text(
                          'Nova conversa',
                          style: TextStyle(
                            color: GamaColors.textPrimary,
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            _DrawerItem(
              icon: Icons.image_outlined,
              label: 'Imagens',
              onTap: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const ImagesScreen()),
                );
              },
            ),
            _DrawerItem(
              icon: Icons.menu_book_outlined,
              label: 'Biblioteca',
              onTap: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const LibraryScreen()),
                );
              },
            ),
            _DrawerItem(
              icon: Icons.folder_outlined,
              label: 'Projetos',
              onTap: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const ProjectsScreen()),
                );
              },
            ),
            _DrawerItem(
              icon: Icons.schedule_outlined,
              label: 'Agendado',
              onTap: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const ScheduledScreen()),
                );
              },
            ),
            _DrawerItem(
              icon: Icons.extension_outlined,
              label: 'Plugins',
              onTap: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const PluginsScreen()),
                );
              },
            ),
            _DrawerItem(
              icon: Icons.settings_outlined,
              label: 'Configurações',
              onTap: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const SettingsScreen()),
                );
              },
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 6),
              child: Text(
                'Conversas',
                style: TextStyle(
                  color: GamaColors.textMuted,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Expanded(
              child: AnimatedBuilder(
                animation: service,
                builder: (context, _) {
                  final items = [
                    ...service.pinnedConversations,
                    ...service.recentConversations,
                  ];
                  if (items.isEmpty) {
                    return const Center(
                      child: Padding(
                        padding: EdgeInsets.all(16),
                        child: Text(
                          'Nenhuma conversa ainda',
                          style: TextStyle(
                            color: GamaColors.textMuted,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    );
                  }
                  return ListView.builder(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                    itemCount: items.length,
                    itemBuilder: (context, index) {
                      final c = items[index];
                      final selected = c.id == service.currentConversationId;
                      return _ConversationTile(
                        conversation: c,
                        isSelected: selected,
                        onTap: () {
                          Navigator.pop(context);
                          onSelectConversation(c.id);
                        },
                        onPin: () => service.togglePin(c.id),
                        onRename: () => _rename(context, service, c),
                        onDelete: () => _delete(context, service, c),
                      );
                    },
                  );
                },
              ),
            ),
            const Divider(color: GamaColors.divider, height: 1),
            ListTile(
              dense: true,
              leading: const Icon(
                Icons.logout_rounded,
                color: GamaColors.textMuted,
                size: 22,
              ),
              title: const Text(
                'Sair da conta',
                style: TextStyle(color: GamaColors.textSecondary, fontSize: 14),
              ),
              onTap: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    backgroundColor: GamaColors.surfaceCard,
                    title: const Text(
                      'Sair?',
                      style: TextStyle(color: GamaColors.textPrimary),
                    ),
                    content: const Text(
                      'Você volta à tela de login. A memória desta conta permanece no servidor.',
                      style: TextStyle(color: GamaColors.textSecondary),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('Cancelar'),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text(
                          'Sair',
                          style: TextStyle(color: GamaColors.error),
                        ),
                      ),
                    ],
                  ),
                );
                if (ok == true && context.mounted) {
                  await AuthService.instance.signOut();
                  if (context.mounted) {
                    Navigator.of(context).pushAndRemoveUntil(
                      MaterialPageRoute(builder: (_) => const LoginScreen()),
                      (_) => false,
                    );
                  }
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _delete(
    BuildContext context,
    ConversationService service,
    Conversation c,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: GamaColors.surfaceCard,
        title: const Text(
          'Apagar conversa?',
          style: TextStyle(color: GamaColors.textPrimary),
        ),
        content: Text(
          '"${c.title}" será apagada permanentemente.',
          style: const TextStyle(color: GamaColors.textSecondary),
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
              style: TextStyle(color: GamaColors.error),
            ),
          ),
        ],
      ),
    );
    if (ok == true) {
      await service.deleteConversation(c.id);
    }
  }

  Future<void> _rename(
    BuildContext context,
    ConversationService service,
    Conversation c,
  ) async {
    final controller = TextEditingController(text: c.title);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: GamaColors.surfaceCard,
        title: const Text(
          'Renomear',
          style: TextStyle(color: GamaColors.textPrimary),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: GamaColors.textPrimary),
          decoration: const InputDecoration(hintText: 'Título'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'Salvar',
              style: TextStyle(color: GamaColors.accent),
            ),
          ),
        ],
      ),
    );
    if (ok == true) {
      final t = controller.text.trim();
      if (t.isNotEmpty) {
        await service.renameConversation(c.id, t);
      }
    }
  }
}

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
      dense: true,
      leading: Icon(icon, color: GamaColors.textMuted, size: 22),
      title: Text(
        label,
        style: const TextStyle(color: GamaColors.textSecondary, fontSize: 14),
      ),
      onTap: onTap,
    );
  }
}

class _ConversationTile extends StatelessWidget {
  final Conversation conversation;
  final bool isSelected;
  final VoidCallback onTap;
  final VoidCallback onPin;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  const _ConversationTile({
    required this.conversation,
    required this.isSelected,
    required this.onTap,
    required this.onPin,
    required this.onRename,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Material(
        color: isSelected
            ? GamaColors.accent.withOpacity(0.1)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: isSelected
                  ? Border.all(color: GamaColors.accent.withOpacity(0.25))
                  : null,
            ),
            child: ListTile(
              title: Text(
                conversation.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: isSelected
                      ? GamaColors.textPrimary
                      : GamaColors.textSecondary,
                  fontSize: 13.5,
                  fontWeight: isSelected ? FontWeight.w500 : FontWeight.w400,
                ),
              ),
              dense: true,
              contentPadding: const EdgeInsets.only(left: 14, right: 4),
              visualDensity: VisualDensity.compact,
              trailing: PopupMenuButton<String>(
                icon: const Icon(
                  Icons.more_horiz,
                  color: GamaColors.textMuted,
                  size: 18,
                ),
                color: GamaColors.surfaceCard,
                onSelected: (value) {
                  if (value == 'pin') onPin();
                  if (value == 'rename') onRename();
                  if (value == 'delete') onDelete();
                },
                itemBuilder: (context) => [
                  PopupMenuItem(
                    value: 'pin',
                    child: Text(
                      conversation.isPinned ? 'Desafixar' : 'Fixar',
                      style: const TextStyle(color: GamaColors.textPrimary),
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'rename',
                    child: Text(
                      'Renomear',
                      style: TextStyle(color: GamaColors.textPrimary),
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'delete',
                    child: Text(
                      'Apagar',
                      style: TextStyle(color: GamaColors.error),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
