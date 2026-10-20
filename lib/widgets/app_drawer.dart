import 'package:flutter/material.dart';

import '../core/gama_colors.dart';
import '../models/conversation.dart';
import '../services/conversation_service.dart';
import '../services/identity_service.dart';
import '../services/auth_service.dart';
import '../screens/login_screen.dart';
import '../screens/settings_screen.dart';
import '../screens/memory_screen.dart';

class AppDrawer extends StatelessWidget {
  final VoidCallback onNewChat;
  final Function(String conversationId) onSelectConversation;
  final VoidCallback? onOpenImages;
  final VoidCallback? onOpenLibrary;
  final VoidCallback? onOpenProjects;
  final VoidCallback? onOpenScheduled;
  final VoidCallback? onOpenPlugins;
  final bool persistent;

  const AppDrawer({
    super.key,
    required this.onNewChat,
    required this.onSelectConversation,
    this.onOpenImages,
    this.onOpenLibrary,
    this.onOpenProjects,
    this.onOpenScheduled,
    this.onOpenPlugins,
    this.persistent = false,
  });

  void _close(BuildContext context) {
    if (!persistent) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final service = ConversationService.instance;
    String conversationQuery = '';

    return Drawer(
      backgroundColor: context.gama.surface,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ===== MINI PERFIL =====
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
              child: Container(
                padding: const EdgeInsets.fromLTRB(12, 14, 8, 14),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      context.gama.surfaceCard,
                      context.gama.surfaceElevated,
                    ],
                  ),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: context.gama.borderSoft),
                ),
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
                            style: TextStyle(
                              color: context.gama.textPrimary,
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            IdentityService.instance.email ??
                                (IdentityService.instance.provider == 'google'
                                    ? 'Conta Google'
                                    : 'Conta de convidado'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: context.gama.textMuted,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.edit_square, size: 20),
                      tooltip: 'Nova conversa',
                      onPressed: onNewChat,
                    ),
                  ],
                ),
              ),
            ),
            // Botão nova conversa
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
              child: Material(
                color: context.gama.accent,
                borderRadius: BorderRadius.circular(16),
                child: InkWell(
                  onTap: onNewChat,
                  borderRadius: BorderRadius.circular(16),
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          context.gama.accentBright,
                          context.gama.accentMuted,
                        ],
                      ),
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: context.gama.accent.withValues(alpha: 0.18),
                          blurRadius: 16,
                          offset: const Offset(0, 5),
                        ),
                      ],
                    ),
                    child: const Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 13,
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.add_rounded,
                            color: Colors.white,
                            size: 21,
                          ),
                          SizedBox(width: 10),
                          Text(
                            'Nova conversa',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.1,
                            ),
                          ),
                        ],
                      ),
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
            _DrawerItem(
              icon: Icons.psychology_outlined,
              label: 'Memória',
              onTap: () {
                _close(context);
                Navigator.of(context).push(MaterialPageRoute(builder: (_) => const MemoryScreen()));
              },
            ),

            Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Divider(color: context.gama.divider, height: 1),
            ),

            // ===== CONVERSAS =====
            Expanded(
              child: ListenableBuilder(
                listenable: service,
                builder: (context, _) => StatefulBuilder(
                  builder: (context, setLocalState) {
                    final query = conversationQuery.trim().toLowerCase();
                    final pinned = service.pinnedConversations
                        .where((c) => _matchesConversation(service, c, query))
                        .toList();
                    final recent = service.recentConversations
                        .where((c) => _matchesConversation(service, c, query))
                        .toList();
                    final groupedRecent = _groupRecentConversations(recent);
                    final hasAny = pinned.isNotEmpty || recent.isNotEmpty;

                    return Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 2, 12, 8),
                          child: TextField(
                            decoration: InputDecoration(
                              hintText: 'Buscar título ou mensagem',
                              prefixIcon: const Icon(
                                Icons.search_rounded,
                                size: 19,
                              ),
                              suffixIcon: query.isEmpty
                                  ? null
                                  : IconButton(
                                      tooltip: 'Limpar busca',
                                      icon: const Icon(
                                        Icons.close_rounded,
                                        size: 18,
                                      ),
                                      onPressed: () => setLocalState(
                                        () => conversationQuery = '',
                                      ),
                                    ),
                              filled: true,
                              fillColor: context.gama.surfaceCard,
                              isDense: true,
                              contentPadding: const EdgeInsets.symmetric(
                                vertical: 10,
                              ),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(13),
                                borderSide: BorderSide(
                                  color: context.gama.border,
                                ),
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(13),
                                borderSide: BorderSide(
                                  color: context.gama.border,
                                ),
                              ),
                            ),
                            style: TextStyle(
                              color: context.gama.textPrimary,
                              fontSize: 13,
                            ),
                            onChanged: (value) =>
                                setLocalState(() => conversationQuery = value),
                          ),
                        ),
                        Expanded(
                          child: !hasAny
                              ? Center(
                                  child: Padding(
                                    padding: const EdgeInsets.all(24),
                                    child: Text(
                                      query.isEmpty
                                          ? 'Nenhuma conversa ainda'
                                          : 'Nenhuma conversa encontrada',
                                      style: TextStyle(
                                        color: context.gama.textMuted,
                                        fontSize: 13,
                                      ),
                                      textAlign: TextAlign.center,
                                    ),
                                  ),
                                )
                              : ListView(
                                  padding: const EdgeInsets.only(bottom: 8),
                                  children: [
                                    if (pinned.isNotEmpty) ...[
                                      const _SectionLabel('Fixados'),
                                      ...pinned.map(
                                        (c) => _ConversationTile(
                                          conversation: c,
                                          searchSnippet: _conversationSnippet(service, c, query),
                                          isSelected:
                                              c.id ==
                                              service.currentConversationId,
                                          onTap: () =>
                                              onSelectConversation(c.id),
                                          onPin: () => service.togglePin(c.id),
                                          onDelete: () =>
                                              _confirmDelete(context, c),
                                          onRename: () =>
                                              _renameDialog(context, c),
                                        ),
                                      ),
                                    ],
                                    for (final entry in groupedRecent.entries)
                                      if (entry.value.isNotEmpty) ...[
                                        _SectionLabel(entry.key),
                                        ...entry.value.map(
                                          (c) => _ConversationTile(
                                            conversation: c,
                                            searchSnippet: _conversationSnippet(service, c, query),
                                            isSelected:
                                                c.id ==
                                                service.currentConversationId,
                                            onTap: () =>
                                                onSelectConversation(c.id),
                                            onPin: () =>
                                                service.togglePin(c.id),
                                            onDelete: () =>
                                                _confirmDelete(context, c),
                                            onRename: () =>
                                                _renameDialog(context, c),
                                          ),
                                        ),
                                      ],
                                  ],
                                ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),

            // ===== RODAPÉ =====
            Divider(color: context.gama.divider, height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
              child: ListTile(
                leading: Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: context.gama.surfaceCard,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: context.gama.border),
                  ),
                  child: Icon(
                    Icons.settings_outlined,
                    color: context.gama.textSecondary,
                    size: 18,
                  ),
                ),
                title: Text(
                  'Configurações',
                  style: TextStyle(
                    color: context.gama.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                dense: true,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                onTap: () {
                  _close(context);
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
                    color: context.gama.surfaceCard,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: context.gama.border),
                  ),
                  child: Icon(
                    Icons.logout_rounded,
                    color: context.gama.error,
                    size: 18,
                  ),
                ),
                title: Text(
                  'Sair da conta',
                  style: TextStyle(
                    color: context.gama.error,
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
    _close(context);
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
    _close(context);
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Em breve')));
  }

  void _confirmDelete(BuildContext context, Conversation c) {
    final service = ConversationService.instance;
    service.stageDeleteConversation(c.id);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Conversa “${c.title}” apagada'),
        duration: const Duration(seconds: 5),
        action: SnackBarAction(
          label: 'Desfazer',
          onPressed: () => service.undoDeleteConversation(c.id),
        ),
      ),
    );
  }

  Future<void> _renameDialog(BuildContext context, Conversation c) async {
    final controller = TextEditingController(text: c.title);

    final newTitle = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: context.gama.surfaceCard,
        title: Text(
          'Renomear conversa',
          style: TextStyle(color: context.gama.textPrimary),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: TextStyle(color: context.gama.textPrimary),
          decoration: const InputDecoration(hintText: 'Título da conversa'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              'Cancelar',
              style: TextStyle(color: context.gama.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: Text('Salvar', style: TextStyle(color: context.gama.accent)),
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
        style: TextStyle(
          color: context.gama.textMuted,
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.3,
        ),
      ),
    );
  }
}

bool _matchesConversation(
  ConversationService service,
  Conversation conversation,
  String query,
) {
  if (query.isEmpty) return true;
  if (conversation.title.toLowerCase().contains(query)) return true;
  // O histórico pode conter imagens inline antigas em base64. Removemos esses
  // blocos da busca para evitar varrer dezenas de megabytes sem valor textual.
  final hiddenImage = RegExp(
    r'\[gama_image\][\s\S]*?\[/gama_image\]|\[gama_image_file\][\s\S]*?\[/gama_image_file\]',
    caseSensitive: false,
  );
  for (final message in service.getMessages(conversation.id)) {
    final text = message.content.replaceAll(hiddenImage, ' ').toLowerCase();
    if (text.contains(query)) return true;
  }
  return false;
}

String? _conversationSnippet(ConversationService service, Conversation conversation, String query) {
  if (query.isEmpty) return null;
  final titleAt = conversation.title.toLowerCase().indexOf(query);
  if (titleAt >= 0) return 'Título: ${conversation.title}';
  final hiddenImage = RegExp(r'\[gama_image\][\s\S]*?\[/gama_image\]|\[gama_image_file\][\s\S]*?\[/gama_image_file\]', caseSensitive: false);
  for (final message in service.getMessages(conversation.id).reversed) {
    final text = message.content.replaceAll(hiddenImage, ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    final at = text.toLowerCase().indexOf(query);
    if (at < 0) continue;
    final start = (at - 35).clamp(0, text.length).toInt();
    final end = (at + query.length + 55).clamp(0, text.length).toInt();
    return '${start > 0 ? '…' : ''}${text.substring(start, end)}${end < text.length ? '…' : ''}';
  }
  return null;
}

Map<String, List<Conversation>> _groupRecentConversations(
  List<Conversation> conversations,
) {
  final groups = <String, List<Conversation>>{
    'Hoje': [],
    'Ontem': [],
    'Últimos 7 dias': [],
    'Mais antigas': [],
  };
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  for (final conversation in conversations) {
    final updated = conversation.updatedAt.toLocal();
    final day = DateTime(updated.year, updated.month, updated.day);
    final daysAgo = today.difference(day).inDays;
    final group = daysAgo <= 0
        ? 'Hoje'
        : daysAgo == 1
        ? 'Ontem'
        : daysAgo <= 7
        ? 'Últimos 7 dias'
        : 'Mais antigas';
    groups[group]!.add(conversation);
  }
  return groups;
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
        leading: Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: context.gama.surfaceCard,
            borderRadius: BorderRadius.circular(11),
            border: Border.all(color: context.gama.borderSoft),
          ),
          child: Icon(icon, color: context.gama.textSecondary, size: 18),
        ),
        title: Text(
          label,
          style: TextStyle(
            color: context.gama.textPrimary,
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
  final String? searchSnippet;

  const _ConversationTile({
    required this.conversation,
    required this.isSelected,
    required this.onTap,
    required this.onPin,
    required this.onDelete,
    required this.onRename,
    this.searchSnippet,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: Material(
        color: isSelected ? context.gama.accentSoft : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: isSelected
                  ? Border.all(
                      color: context.gama.accent.withValues(alpha: 0.25),
                    )
                  : null,
            ),
            child: ListTile(
              leading: isSelected
                  ? Container(
                      width: 3,
                      height: 18,
                      decoration: BoxDecoration(
                        color: context.gama.accent,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    )
                  : conversation.isPinned
                  ? Icon(
                      Icons.push_pin,
                      size: 14,
                      color: context.gama.textMuted,
                    )
                  : const SizedBox(width: 3),
              title: Text(
                conversation.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: isSelected
                      ? context.gama.textPrimary
                      : context.gama.textSecondary,
                  fontSize: 13.5,
                  fontWeight: isSelected ? FontWeight.w500 : FontWeight.w400,
                ),
              ),
              subtitle: searchSnippet == null ? null : Text(searchSnippet!, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: context.gama.textMuted, fontSize: 11)),
              dense: true,
              contentPadding: const EdgeInsets.only(left: 10, right: 4),
              visualDensity: VisualDensity.compact,
              trailing: PopupMenuButton<String>(
                icon: Icon(
                  Icons.more_horiz,
                  color: context.gama.textMuted,
                  size: 18,
                ),
                color: context.gama.surfaceCard,
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
                      style: TextStyle(color: context.gama.textPrimary),
                    ),
                  ),
                  PopupMenuItem(
                    value: 'rename',
                    child: Text(
                      'Renomear',
                      style: TextStyle(color: context.gama.textPrimary),
                    ),
                  ),
                  PopupMenuItem(
                    value: 'delete',
                    child: Text(
                      'Apagar',
                      style: TextStyle(color: context.gama.error),
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
        color: context.gama.accentSoft,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.gama.accent.withValues(alpha: 0.35)),
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
                style: TextStyle(
                  color: context.gama.accent,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
            )
          : Text(
              letter,
              style: TextStyle(
                color: context.gama.accent,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
    );
  }
}
