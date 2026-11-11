import 'package:flutter/material.dart';

import '../core/constants.dart';
import '../utils/local_calendar.dart';
import '../core/gama_page_route.dart';
import '../core/gama_colors.dart';
import 'gama_floating_page.dart';
import '../models/conversation.dart';
import '../models/oficina_kind.dart';
import '../services/conversation_service.dart';
import '../services/identity_service.dart';
import '../screens/settings_screen.dart';
import '../screens/account_screen.dart';
import '../screens/commercial_screen.dart';

class AppDrawer extends StatefulWidget {
  final VoidCallback onNewChat;
  final Function(String conversationId) onSelectConversation;
  final VoidCallback? onOpenLibrary;
  final VoidCallback? onOpenProjects;
  final VoidCallback? onOpenScheduled;
  final VoidCallback? onOpenPlugins;
  final VoidCallback? onOpenOficina;
  final VoidCallback? onOpenWelcome;
  final bool persistent;
  final FocusNode? searchFocusNode;

  const AppDrawer({
    super.key,
    required this.onNewChat,
    required this.onSelectConversation,
    this.onOpenLibrary,
    this.onOpenProjects,
    this.onOpenScheduled,
    this.onOpenPlugins,
    this.onOpenOficina,
    this.onOpenWelcome,
    this.persistent = false,
    this.searchFocusNode,
  });

  @override
  State<AppDrawer> createState() => _AppDrawerState();
}

class _AppDrawerState extends State<AppDrawer> {
  final TextEditingController _conversationSearchController = TextEditingController();
  String conversationQuery = '';

  void _updateSearch(String value) {
    if (value == conversationQuery) return;
    setState(() => conversationQuery = value);
  }

  VoidCallback get onNewChat => widget.onNewChat;
  Function(String) get onSelectConversation => widget.onSelectConversation;
  VoidCallback? get onOpenLibrary => widget.onOpenLibrary;
  VoidCallback? get onOpenProjects => widget.onOpenProjects;
  VoidCallback? get onOpenScheduled => widget.onOpenScheduled;
  VoidCallback? get onOpenPlugins => widget.onOpenPlugins;
  VoidCallback? get onOpenOficina => widget.onOpenOficina;
  VoidCallback? get onOpenWelcome => widget.onOpenWelcome;
  bool get persistent => widget.persistent;

  @override
  void dispose() {
    _conversationSearchController.dispose();
    super.dispose();
  }

  void _close(BuildContext context) {
    if (!persistent) Navigator.pop(context);
  }

  void _openPage(BuildContext context, Widget page) {
    final navigator = Navigator.of(context);
    _close(context);
    navigator.push(GamaPageRoute<void>(builder: (_) => page));
  }

  @override
  Widget build(BuildContext context) {
    final service = ConversationService.instance;

    return Drawer(
      backgroundColor: context.gama.surface,
      child: Stack(
        children: [
          const Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: IgnorePointer(child: GamaTopShade()),
          ),
          SafeArea(
            child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // PERFIL — área única, sem uma segunda ação de criar conversa.
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
              child: Material(
                color: context.gama.surfaceCard,
                borderRadius: BorderRadius.circular(16),
                child: InkWell(
                  key: const Key('drawer-account-entry'),
                  onTap: () => _openPage(context, const AccountScreen()),
                  borderRadius: BorderRadius.circular(16),
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: context.gama.borderSoft),
                    ),
                    child: Row(
                      children: [
                        const _ProfileAvatar(size: 40),
                        const SizedBox(width: 10),
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
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                'Conta e privacidade',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: context.gama.textMuted,
                                  fontSize: 11.5,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (onOpenWelcome != null)
                          IconButton(
                            icon: const Icon(Icons.help_outline_rounded, size: 19),
                            tooltip: 'Conheça a $kAppName',
                            onPressed: onOpenWelcome,
                          ),
                        Icon(Icons.chevron_right_rounded,
                            size: 18, color: context.gama.textMuted),
                        const SizedBox(width: 3),
                      ],
                    ),
                  ),
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
                      // Superfície sólida: o texto mantém contraste em ambos os temas.
                      color: context.gama.accent,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: context.gama.accent.withValues(alpha: 0.18),
                          blurRadius: 16,
                          offset: const Offset(0, 5),
                        ),
                      ],
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 13,
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.add_rounded,
                            color: context.gama.onAccent,
                            size: 21,
                          ),
                          const SizedBox(width: 10),
                          Text(
                            'Nova conversa',
                            style: TextStyle(
                              color: context.gama.onAccent,
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

            const SizedBox(height: 8),
            const _SectionLabel('Ferramentas'),
            _DrawerItem(
              icon: Icons.handyman_outlined,
              label: 'Oficina',
              onTap: onOpenOficina ?? () => _comingSoon(context),
              emphasized: true,
            ),
            _DrawerItem(
              icon: Icons.menu_book_outlined,
              label: 'Biblioteca',
              onTap: onOpenLibrary ?? () => _comingSoon(context),
            ),
            _DrawerItem(
              icon: Icons.schedule_outlined,
              label: 'Agendamentos',
              onTap: onOpenScheduled ?? () => _comingSoon(context),
            ),
            _DrawerItem(
              icon: Icons.extension_outlined,
              label: 'Recursos e integrações',
              onTap: onOpenPlugins ?? () => _comingSoon(context),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
              child: Divider(color: context.gama.divider, height: 1),
            ),

            // HISTÓRICO: conversas fixadas permanecem aqui, e a página
            // completa continua disponível sem ocupar um item principal.
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 10, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text('Histórico', style: TextStyle(
                      color: context.gama.textMuted,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    )),
                  ),
                  if (onOpenProjects != null)
                    TextButton.icon(
                      key: const Key('drawer-pinned-shortcut'),
                      onPressed: onOpenProjects,
                      style: TextButton.styleFrom(
                        foregroundColor: context.gama.textSecondary,
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                      ),
                      icon: const Icon(Icons.push_pin_outlined, size: 15),
                      label: const Text('Fixadas', style: TextStyle(fontSize: 12)),
                    ),
                ],
              ),
            ),

            // ===== CONVERSAS =====
            Expanded(
              child: ListenableBuilder(
                listenable: service,
                builder: (context, _) {

                    final query = conversationQuery.trim().toLowerCase();
                    // Uma única busca calcula tanto o filtro quanto o trecho
                    // exibido; evita reler as mesmas mensagens duas vezes.
                    final snippets = <String, String?>{};
                    bool matches(Conversation c) {
                      if (query.isEmpty) return true;
                      final snippet = _conversationSnippet(service, c, query);
                      if (snippet == null) return false;
                      snippets[c.id] = snippet;
                      return true;
                    }
                    final pinned = service.pinnedConversations.where(matches).toList();
                    final recent = service.recentConversations.where(matches).toList();
                    final groupedRecent = _groupRecentConversations(recent);
                    final hasAny = pinned.isNotEmpty || recent.isNotEmpty;

                    return Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 2, 12, 8),
                          child: TextField(
                            controller: _conversationSearchController,
                            focusNode: widget.searchFocusNode,
                            textInputAction: TextInputAction.search,
                            decoration: InputDecoration(
                              hintText: 'Buscar conversas',
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
                                      onPressed: () {
                                        _conversationSearchController.clear();
                                        _updateSearch('');
                                      },
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
                            onChanged: _updateSearch,
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
                                          searchSnippet: snippets[c.id],
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
                                            searchSnippet: snippets[c.id],
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

            // RODAPÉ: atalhos legíveis; o encerramento da sessão fica
            // em Conta e privacidade, com confirmação explícita.
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
              child: Divider(color: context.gama.divider, height: 1),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
              child: Row(
                children: [
                  Expanded(
                    child: _DrawerFooterButton(
                      icon: Icons.workspace_premium_outlined,
                      label: 'Meu plano',
                      foreground: context.gama.accent,
                      onPressed: () => _openPage(context, const CommercialScreen()),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _DrawerFooterButton(
                      icon: Icons.settings_outlined,
                      label: 'Configurações',
                      foreground: context.gama.textSecondary,
                      onPressed: () => _openPage(context, const SettingsScreen()),
                    ),
                  ),
                ],
              ),
            ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _comingSoon(BuildContext context) {
    final messenger = ScaffoldMessenger.of(context);
    _close(context);
    messenger.showSnackBar(const SnackBar(content: Text('Em breve')));
  }

  void _confirmDelete(BuildContext context, Conversation c) {
    final service = ConversationService.instance;
    service.stageDeleteConversation(c.id);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Conversa “${c.title}” apagada'),
        duration: const Duration(seconds: 3),
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

    // A dialog's TextField no longer owns this controller after closing.
    final cleanTitle = newTitle?.trim();
    WidgetsBinding.instance.addPostFrameCallback((_) => controller.dispose());
    if (cleanTitle != null && cleanTitle.isNotEmpty && cleanTitle != c.title) {
      await ConversationService.instance.renameConversation(c.id, cleanTitle);
    }
  }
}

// Botões independentes, com rótulos acessíveis e alvo de toque de 48 px.
// O estilo usa a mesma superfície dos controles flutuantes do aplicativo.
class _DrawerFooterButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color foreground;
  final VoidCallback onPressed;

  const _DrawerFooterButton({
    required this.icon,
    required this.label,
    required this.foreground,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) => Material(
    color: context.gama.surfaceCard,
    borderRadius: BorderRadius.circular(12),
    child: InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        constraints: const BoxConstraints(minHeight: 46),
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 6),
        decoration: BoxDecoration(
          border: Border.all(color: context.gama.borderSoft),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 18, color: foreground),
            const SizedBox(width: 7),
            Flexible(child: Text(label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: context.gama.textPrimary, fontSize: 12.5),
            )),
          ],
        ),
      ),
    ),
  );
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

final RegExp _hiddenImagesInHistory = RegExp(
  r'\[gama_image\][\s\S]*?\[/gama_image\]|\[gama_image_file\][\s\S]*?\[/gama_image_file\]',
  caseSensitive: false,
);
final RegExp _historyWhitespace = RegExp(r'\s+');

String? _conversationSnippet(
  ConversationService service,
  Conversation conversation,
  String query,
) {
  if (query.isEmpty) return null;
  final titleAt = conversation.title.toLowerCase().indexOf(query);
  if (titleAt >= 0) return 'Título: ${conversation.title}';
  for (final message in service.getMessages(conversation.id).reversed) {
    final text = message.content
        .replaceAll(_hiddenImagesInHistory, ' ')
        .replaceAll(_historyWhitespace, ' ')
        .trim();
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
  for (final conversation in conversations) {
    final daysAgo = localDaysAgo(conversation.updatedAt, now);
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
  final bool emphasized;

  const _DrawerItem({
    required this.icon,
    required this.label,
    required this.onTap,
    this.emphasized = false,
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
            color: emphasized ? context.gama.accentSoft : context.gama.surfaceCard,
            borderRadius: BorderRadius.circular(11),
            border: Border.all(color: context.gama.borderSoft),
          ),
          child: Icon(icon,
              color: emphasized ? context.gama.accent : context.gama.textSecondary,
              size: 18),
        ),
        title: Text(
          label,
          style: TextStyle(
            color: context.gama.textPrimary,
            fontSize: 14,
            fontWeight: emphasized ? FontWeight.w600 : FontWeight.w400,
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
              leading: OficinaKindX.fromChatMode(conversation.mode) != null
                  ? Icon(
                      OficinaKindX.fromChatMode(conversation.mode)!.icon,
                      size: 16,
                      color: isSelected
                          ? context.gama.accent
                          : context.gama.textMuted,
                    )
                  : isSelected
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
              subtitle: searchSnippet == null
                  ? null
                  : Text(
                      searchSnippet!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: context.gama.textMuted,
                        fontSize: 12,
                      ),
                    ),
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
