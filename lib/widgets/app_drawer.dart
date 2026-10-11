import 'package:flutter/material.dart';

import '../core/gama_colors.dart';
import '../models/conversation.dart';
import '../services/conversation_service.dart';
import '../services/identity_service.dart';
import '../services/auth_service.dart';
import '../screens/login_screen.dart';
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
      backgroundColor: GamaColors.surfaceElevated,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ===== MINI PERFIL =====
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
              child: Row(
                children: [
                  const _ProfileAvatar(size: 44),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          IdentityService.instance.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: GamaColors.textPrimary,
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          IdentityService.instance.email ??
                              (IdentityService.instance.provider == 'google'
                                  ? 'Conta Google'
                                  : 'Convidado'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: GamaColors.textMuted,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(
                      Icons.edit_square,
                      color: GamaColors.textSecondary,
                      size: 22,
                    ),
                    tooltip: 'Nova conversa',
                    onPressed: onNewChat,
                  ),
                ],
              ),
            ),
            // Botão nova conversa
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Material(
                color: GamaColors.surfaceCard,
                borderRadius: BorderRadius.circular(14),
                child: InkWell(
                  onTap: onNewChat,
                  borderRadius: BorderRadius.circular(14),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 13,
                    ),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: GamaColors.border),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.2),
                          blurRadius: 6,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: const Row(
                      children: [
                        Icon(Icons.add, color: GamaColors.accent, size: 20),
                        SizedBox(width: 10),
                        Text(
                          'Nova conversa',
                          style: TextStyle(
                            color: GamaColors.textPrimary,
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),

            const SizedBox(height: 4),

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

            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Divider(color: GamaColors.divider, height: 1),
            ),

            // ===== CONVERSAS =====
            Expanded(
              child: ListenableBuilder(
                listenable: service,
                builder: (context, _) {
                  final pinned = service.pinnedConversations;
                  final recent = service.recentConversations;

                  if (pinned.isEmpty && recent.isEmpty) {
                    return const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
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

                  return ListView(
                    padding: const EdgeInsets.only(bottom: 8),
                    children: [
                      if (pinned.isNotEmpty) ...[
                        const _SectionLabel('Fixados'),
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
                      if (recent.isNotEmpty) ...[
                        const _SectionLabel('Recentes'),
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
                    ],
                  );
                },
              ),
            ),

            // ===== RODAPÉ =====
            const Divider(color: GamaColors.divider, height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
              child: ListTile(
                leading: Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: GamaColors.surfaceCard,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: GamaColors.border),
                  ),
                  child: const Icon(
                    Icons.settings_outlined,
                    color: GamaColors.textSecondary,
                    size: 18,
                  ),
                ),
                title: const Text(
                  'Configurações',
                  style: TextStyle(
                    color: GamaColors.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                dense: true,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const SettingsScreen()),
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: ListTile(
                leading: Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: GamaColors.surfaceCard,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: GamaColors.border),
                  ),
                  child: const Icon(
                    Icons.logout_rounded,
                    color: GamaColors.error,
                    size: 18,
                  ),
                ),
                title: const Text(
                  'Sair da conta',
                  style: TextStyle(
                    color: GamaColors.error,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                dense: true,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                onTap: () => _logout(context),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _logout(BuildContext context) async {
    Navigator.pop(context);
    try {
      await AuthService.instance.signOut();
    } catch (_) {
      await IdentityService.instance.signOutLocal();
    }
    if (!context.mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => const LoginScreen(),
        transitionDuration: const Duration(milliseconds: 350),
        transitionsBuilder: (_, a, __, child) =>
            FadeTransition(opacity: a, child: child),
      ),
      (_) => false,
    );
  }

  void _comingSoon(BuildContext context) {
    Navigator.pop(context);
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Em breve')));
  }

  Future<void> _confirmDelete(BuildContext context, Conversation c) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: GamaColors.surfaceCard,
        title: const Text(
          'Apagar conversa?',
          style: TextStyle(color: GamaColors.textPrimary),
        ),
        content: Text(
          '“${c.title}” será apagada permanentemente.',
          style: const TextStyle(color: GamaColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text(
              'Cancelar',
              style: TextStyle(color: GamaColors.textSecondary),
            ),
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

    if (confirm == true) {
      await ConversationService.instance.deleteConversation(c.id);
    }
  }

  Future<void> _renameDialog(BuildContext context, Conversation c) async {
    final controller = TextEditingController(text: c.title);

    final newTitle = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: GamaColors.surfaceCard,
        title: const Text(
          'Renomear conversa',
          style: TextStyle(color: GamaColors.textPrimary),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: GamaColors.textPrimary),
          decoration: const InputDecoration(hintText: 'Título da conversa'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text(
              'Cancelar',
              style: TextStyle(color: GamaColors.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text(
              'Salvar',
              style: TextStyle(color: GamaColors.accent),
            ),
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

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
      child: Text(
        text,
        style: const TextStyle(
          color: GamaColors.textMuted,
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.3,
        ),
      ),
    );
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
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: ListTile(
        leading: Icon(icon, color: GamaColors.textSecondary, size: 20),
        title: Text(
          label,
          style: const TextStyle(
            color: GamaColors.textPrimary,
            fontSize: 14,
            fontWeight: FontWeight.w400,
          ),
        ),
        onTap: onTap,
        dense: true,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12),
        visualDensity: VisualDensity.compact,
      ),
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
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: Material(
        color: isSelected ? GamaColors.accentSoft : Colors.transparent,
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
              leading: isSelected
                  ? Container(
                      width: 3,
                      height: 18,
                      decoration: BoxDecoration(
                        color: GamaColors.accent,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    )
                  : conversation.isPinned
                  ? const Icon(
                      Icons.push_pin,
                      size: 14,
                      color: GamaColors.textMuted,
                    )
                  : const SizedBox(width: 3),
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
              contentPadding: const EdgeInsets.only(left: 10, right: 4),
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

class _ProfileAvatar extends StatelessWidget {
  final double size;
  const _ProfileAvatar({this.size = 44});

  @override
  Widget build(BuildContext context) {
    final id = IdentityService.instance;
    final photo = id.photoUrl;
    final letter = id.displayName.isNotEmpty
        ? id.displayName[0].toUpperCase()
        : 'G';
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: GamaColors.accentSoft,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: GamaColors.accent.withOpacity(0.35)),
      ),
      clipBehavior: Clip.antiAlias,
      alignment: Alignment.center,
      child: photo != null && photo.isNotEmpty
          ? Image.network(
              photo,
              width: size,
              height: size,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => Text(
                letter,
                style: const TextStyle(
                  color: GamaColors.accent,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
            )
          : Text(
              letter,
              style: const TextStyle(
                color: GamaColors.accent,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
    );
  }
}
