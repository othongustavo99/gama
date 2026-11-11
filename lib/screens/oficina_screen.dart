import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../widgets/gama_floating_page.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/local_account_scope.dart';

import '../core/gama_page_route.dart';
import '../core/gama_colors.dart';
import '../core/responsive_layout.dart';
import '../models/conversation.dart';
import '../models/oficina_kind.dart';
import '../services/conversation_service.dart';
import 'chat_screen.dart';
import '../widgets/app_drawer.dart';
import '../widgets/windows_conversation_shortcuts.dart';
import 'library_screen.dart';
import 'plugins_screen.dart';
import 'projects_screen.dart';
import 'scheduled_screen.dart';
import '../utils/error_logger.dart';
import '../utils/local_file_metadata.dart';

/// Hub da Oficina: visual alinhado à chat screen, com 3 caminhos de criação.
class OficinaScreen extends StatefulWidget {
  /// Quando aberto a partir de um bloco de código, entra em Programar
  /// com o código no rascunho (sem enviar automaticamente para o servidor).
  final String? initialCode;
  final String? initialLanguage;

  const OficinaScreen({super.key, this.initialCode, this.initialLanguage});

  @override
  State<OficinaScreen> createState() => _OficinaScreenState();
}

class _OficinaScreenState extends State<OficinaScreen> {
  late Future<List<Map<String, dynamic>>> _libraryFuture;

  @override
  void initState() {
    super.initState();
    _libraryFuture = _loadLibrary();
    if (widget.initialCode != null && widget.initialCode!.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final lang = widget.initialLanguage?.trim();
        final title = (lang == null || lang.isEmpty)
            ? 'código'
            : 'código $lang';
        final draft =
            'Revise este $title, explique melhorias e sugira correções sem quebrar o comportamento atual:\n\n```$lang\n${widget.initialCode}\n```';
        _openKind(context, OficinaKind.programar, prompt: draft);
      });
    }
  }

  Future<List<Map<String, dynamic>>> _loadLibrary() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(LocalAccountScope.current().libraryPrefsKey) ?? '[]';
    try {
      final entries = (jsonDecode(raw) as List)
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList()
          .reversed
          .toList();
      final images = entries.where((e) => e['kind'] == 'image').toList();
      final metadata = await loadLocalFileMetadata(images);
      for (final image in images) {
        final path = image['path']?.toString();
        image['_available'] = path != null && (metadata[path]?.hasContent ?? false);
      }
      return entries;
    } catch (error, stack) {
      logSwallowed(error, stack);
      return const [];
    }
  }

  Future<void> _openKind(
    BuildContext context,
    OficinaKind kind, {
    String? prompt,
  }) async {
    await HapticFeedback.selectionClick();
    final conv = await ConversationService.instance.createDetachedConversation(
      mode: kind.chatMode,
    );
    if (!context.mounted) return;
    await Navigator.of(context).push(
      GamaPageRoute<void>(
        builder: (_) => _OficinaScaffold(
          child: ChatScreen(
            conversationId: conv.id,
            oficinaKind: kind,
            initialPrompt: prompt,
            codeComparisonBase: kind == OficinaKind.programar
                ? widget.initialCode
                : null,
            codeComparisonLanguage: kind == OficinaKind.programar
                ? widget.initialLanguage
                : null,
            persistentSidebar: GamaResponsiveLayout.showPersistentSidebar(
              isWindows: defaultTargetPlatform == TargetPlatform.windows,
              windowWidth: MediaQuery.sizeOf(context).width,
            ),
          ),
        ),
      ),
    );
    if (mounted) setState(() => _libraryFuture = _loadLibrary());
  }

  Future<void> _openRecent(
    BuildContext context,
    Conversation conversation,
  ) async {
    final kind = OficinaKindX.fromChatMode(conversation.mode);
    if (kind == null) return;
    if (!context.mounted) return;
    await Navigator.of(context).push(
      GamaPageRoute<void>(
        builder: (_) => _OficinaScaffold(
          child: ChatScreen(
            conversationId: conversation.id,
            oficinaKind: kind,
            persistentSidebar: GamaResponsiveLayout.showPersistentSidebar(
              isWindows: defaultTargetPlatform == TargetPlatform.windows,
              windowWidth: MediaQuery.sizeOf(context).width,
            ),
          ),
        ),
      ),
    );
    if (mounted) setState(() => _libraryFuture = _loadLibrary());
  }

  @override
  Widget build(BuildContext context) {
    final g = context.gama;

    return _OficinaScaffold(
      title: 'Oficina',
      child: ColoredBox(
        color: g.background,
        child: LayoutBuilder(
          builder: (context, constraints) {
            // Use a largura *disponível* após a barra lateral, não apenas o SO.
            final columns = GamaResponsiveLayout.oficinaColumns(
              constraints.maxWidth,
            );
            final textScale = MediaQuery.textScalerOf(context).scale(1.0);
            final cardHeight = textScale > 1.6 ? 430.0 : textScale > 1.25 ? 376.0 : 334.0;
            // Pinned e recentes podem conter a mesma conversa; não repetir.
            final unique = <String, Conversation>{};
            for (final conversation in [
              ...ConversationService.instance.pinnedConversations,
              ...ConversationService.instance.recentConversations,
            ]) {
              unique[conversation.id] = conversation;
            }
            final conversations = unique.values.toList()
              ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
            final recent = conversations
                .where((c) => OficinaKindX.fromChatMode(c.mode) != null)
                .take(8)
                .toList();
            return Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1180),
                child: CustomScrollView(
                  slivers: [
                    SliverPadding(
                      padding: EdgeInsets.fromLTRB(
                        24, MediaQuery.paddingOf(context).top + 82, 24, 20,
                      ),
                      sliver: SliverToBoxAdapter(
                        child: Column(
                          children: [
                            Hero(
                              tag: 'oficina-hub-icon',
                              child: Container(
                                width: 68,
                                height: 68,
                                decoration: BoxDecoration(
                                  color: g.surfaceCard,
                                  borderRadius: BorderRadius.circular(20),
                                  border: Border.all(color: g.border),
                                ),
                                child: Icon(
                                  Icons.handyman_rounded,
                                  size: 32,
                                  color: g.textPrimary,
                                ),
                              ),
                            ),
                            const SizedBox(height: 14),
                            Text(
                              'Sua Oficina',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: g.textPrimary,
                                fontSize: 25,
                                fontWeight: FontWeight.w700,
                                letterSpacing: -0.6,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Imagem, vídeo e código em um só lugar.',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: g.textMuted,
                                fontSize: 14,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    SliverPadding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      sliver: SliverGrid(
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: columns,
                          crossAxisSpacing: 16,
                          mainAxisSpacing: 16,
                          mainAxisExtent: cardHeight,
                        ),
                        delegate: SliverChildBuilderDelegate((context, index) {
                          final kind = OficinaKind.values[index];
                          return _OficinaCard(
                            kind: kind,
                            staggerIndex: index,
                            onTap: () => _openKind(context, kind),
                          );
                        }, childCount: OficinaKind.values.length),
                      ),
                    ),
                    if (recent.isNotEmpty)
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(24, 30, 24, 36),
                        sliver: SliverToBoxAdapter(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Recentes da Oficina',
                                style: TextStyle(
                                  color: g.textPrimary,
                                  fontSize: 18,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 14),
                              SizedBox(
                                height: 178,
                                child:
                                    FutureBuilder<List<Map<String, dynamic>>>(
                                      future: _libraryFuture,
                                      builder: (context, snapshot) =>
                                          ListView.separated(
                                            scrollDirection: Axis.horizontal,
                                            itemCount: recent.length,
                                            separatorBuilder: (_, __) =>
                                                const SizedBox(width: 12),
                                            itemBuilder: (context, index) {
                                              final conversation =
                                                  recent[index];
                                              final kind =
                                                  OficinaKindX.fromChatMode(
                                                    conversation.mode,
                                                  )!;
                                              final messages =
                                                  ConversationService.instance
                                                      .getMessages(
                                                        conversation.id,
                                                      );
                                              final prompt = messages
                                                  .where((m) => m.isUser)
                                                  .map((m) => m.content.trim())
                                                  .firstWhere(
                                                    (text) => text.isNotEmpty,
                                                    orElse: () =>
                                                        conversation.title,
                                                  );
                                              final entry = snapshot.data
                                                  ?.firstWhere(
                                                    (e) =>
                                                        e['conversationId'] ==
                                                            conversation.id &&
                                                        e['kind'] == 'image',
                                                    orElse: () =>
                                                        <String, dynamic>{},
                                                  );
                                              final imagePath = entry?['path']
                                                  ?.toString();
                                              return _RecentCreation(
                                                kind: kind,
                                                title: conversation.title,
                                                prompt: prompt,
                                                imagePath: imagePath,
                                                hasImage: entry?['_available'] == true,
                                                onTap: () => _openRecent(
                                                  context,
                                                  conversation,
                                                ),
                                              );
                                            },
                                          ),
                                    ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Usa o mesmo AppDrawer do chat. No Windows ele fica fixo à esquerda em todas
/// as telas da Oficina; nas demais plataformas abre como drawer móvel.
class _OficinaScaffold extends StatefulWidget {
  final Widget child;
  final String? title;

  const _OficinaScaffold({required this.child, this.title});

  @override
  State<_OficinaScaffold> createState() => _OficinaScaffoldState();
}

class _OficinaScaffoldState extends State<_OficinaScaffold> {
  final _search = ConversationSearchFocus();
  bool _openingConversation = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _newConversation() async {
    if (_openingConversation) return;
    _openingConversation = true;
    try {
      await ConversationService.instance.openFreshConversation();
      if (mounted) _returnToHome(context);
    } finally {
      _openingConversation = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final desktop = GamaResponsiveLayout.showPersistentSidebar(
      isWindows: defaultTargetPlatform == TargetPlatform.windows,
      windowWidth: MediaQuery.sizeOf(context).width,
    );
    final service = ConversationService.instance;
    final drawer = AppDrawer(
      persistent: desktop,
      searchFocusNode: _search.searchNode,
      onNewChat: _newConversation,
      onSelectConversation: (id) async {
        await service.selectConversation(id);
        if (context.mounted) _returnToHome(context);
      },
      onOpenLibrary: () => _open(context, const LibraryScreen(), desktop),
      onOpenProjects: () => _open(context, const ProjectsScreen(), desktop),
      onOpenScheduled: () => _open(context, const ScheduledScreen(), desktop),
      onOpenPlugins: () => _open(context, const PluginsScreen(), desktop),
      onOpenOficina: () {
        if (widget.title != null) {
          if (!desktop) Navigator.pop(context);
          return;
        }
        _open(context, const OficinaScreen(), desktop);
      },
    );

    final content = Builder(
      // O drawer móvel pertence ao Scaffold externo; os controles flutuantes
      // do hub acessam esse Scaffold por meio deste contexto.
      builder: (drawerContext) => widget.title == null
          ? widget.child
          : Scaffold(
              backgroundColor: context.gama.background,

              body: GamaFloatingPage(
                showBack: false,
                contentBehindHeader: true,
                leading: Builder(
                  builder: (buttonContext) => IconButton(
                    tooltip: desktop ? 'Voltar à conversa' : 'Abrir conversas',
                    icon: Icon(desktop ? Icons.arrow_back_rounded : Icons.menu_rounded),
                    onPressed: () => desktop
                        ? Navigator.of(context).pop()
                        : Scaffold.of(drawerContext).openDrawer(),
                  ),
                ),
                child: widget.child,
              ),
            ),
    );

    return WindowsConversationShortcuts(
      autofocus: widget.title != null,
      onNewConversation: _newConversation,
      onSearch: () => _search.requestSearch(persistent: desktop),
      child: Scaffold(
      key: _search.scaffoldKey,
      onDrawerChanged: _search.drawerChanged,
      backgroundColor: context.gama.background,
      drawer: desktop ? null : drawer,
      body: desktop
          ? Row(
              children: [
                SizedBox(width: 280, child: drawer),
                VerticalDivider(
                  width: 1,
                  thickness: 1,
                  color: context.gama.divider,
                ),
                Expanded(child: content),
              ],
            )
          : content,
      ),
    );
  }

  void _open(BuildContext context, Widget screen, bool desktop) {
    if (!desktop) Navigator.pop(context);
    Navigator.of(context).push(GamaPageRoute<void>(builder: (_) => screen));
  }

  /// Sai das rotas temporárias da Oficina para o chat principal. Com isso, a
  /// seleção da conversa atualizada pelo ConversationService aparece no Home.
  void _returnToHome(BuildContext context) {
    _search.closeDrawer();
    Navigator.of(context).popUntil((route) => route.isFirst);
  }
}

class _OficinaCardAsset {
  static String forKind(OficinaKind kind) => switch (kind) {
    OficinaKind.imagem => 'assets/cards/cardMode1.jpeg',
    OficinaKind.video => 'assets/cards/cardMode2.jpeg',
    OficinaKind.programar => 'assets/cards/cardMode3.jpeg',
  };
}

class _OficinaCard extends StatelessWidget {
  final OficinaKind kind;
  final int staggerIndex;
  final VoidCallback onTap;

  const _OficinaCard({
    required this.kind,
    required this.staggerIndex,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => _AnimatedOficinaCard(
    kind: kind,
    staggerIndex: staggerIndex,
    onTap: onTap,
  );
}

class _AnimatedOficinaCard extends StatefulWidget {
  final OficinaKind kind;
  final int staggerIndex;
  final VoidCallback onTap;

  const _AnimatedOficinaCard({
    required this.kind,
    required this.staggerIndex,
    required this.onTap,
  });

  @override
  State<_AnimatedOficinaCard> createState() => _AnimatedOficinaCardState();
}

class _AnimatedOficinaCardState extends State<_AnimatedOficinaCard> {
  bool _pressed = false;
  bool _visible = false;

  @override
  void initState() {
    super.initState();
    Future<void>.delayed(Duration(milliseconds: 90 * widget.staggerIndex), () {
      if (mounted) setState(() => _visible = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.gama;
    final kind = widget.kind;
    final accent = kind.color(palette);
    final reduceMotion = MediaQuery.of(context).disableAnimations;
    final scale = MediaQuery.textScalerOf(context).scale(1.0);

    return AnimatedOpacity(
      opacity: (_visible || reduceMotion) ? 1 : 0,
      duration: reduceMotion ? Duration.zero : const Duration(milliseconds: 360),
      curve: Curves.easeOut,
      child: AnimatedSlide(
        offset: (_visible || reduceMotion) ? Offset.zero : const Offset(0, 0.08),
        duration: reduceMotion ? Duration.zero : const Duration(milliseconds: 360),
        curve: Curves.easeOutCubic,
        child: AnimatedScale(
          scale: _pressed ? 0.985 : 1,
          duration: reduceMotion ? Duration.zero : const Duration(milliseconds: 110),
          curve: Curves.easeOut,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: palette.borderSoft),
              boxShadow: [BoxShadow(
                color: Colors.black.withValues(alpha: 0.09),
                blurRadius: 16,
                offset: const Offset(0, 5),
              )],
            ),
            child: Material(
              color: palette.surfaceCard,
              borderRadius: BorderRadius.circular(22),
              clipBehavior: Clip.antiAlias,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // A arte quadrada ocupa todo o card, sem recortes ou
                  // molduras internas. O assunto principal fica embaixo.
                  Image.asset(
                    _OficinaCardAsset.forKind(kind),
                    fit: BoxFit.cover,
                    alignment: Alignment.bottomCenter,
                    errorBuilder: (context, error, stackTrace) =>
                        ColoredBox(color: palette.surfaceCard),
                  ),
                  // Só escurece levemente a área de leitura. A arte colorida
                  // da metade inferior continua visível.
                  const IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          stops: [0.0, 0.38, 0.60, 1.0],
                          colors: [
                            Color(0x5C000000),
                            Color(0x30000000),
                            Color(0x08000000),
                            Color(0x00000000),
                          ],
                        ),
                      ),
                    ),
                  ),
                  Material(
                    type: MaterialType.transparency,
                    child: InkWell(
                      onTap: widget.onTap,
                      onTapDown: (_) => setState(() => _pressed = true),
                      onTapCancel: () => setState(() => _pressed = false),
                      onTapUp: (_) => setState(() => _pressed = false),
                      splashColor: accent.withValues(alpha: 0.09),
                      highlightColor: accent.withValues(alpha: 0.04),
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(18, scale > 1.25 ? 16 : 20, 18, 16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    kind.label,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 21,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: -0.4,
                                      shadows: [Shadow(color: Color(0x55000000), blurRadius: 8)],
                                    ),
                                  ),
                                ),
                                Container(
                                  width: 36,
                                  height: 36,
                                  decoration: BoxDecoration(
                                    color: const Color(0xA51C2028),
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(color: accent.withValues(alpha: 0.48)),
                                  ),
                                  child: const Icon(Icons.arrow_outward_rounded,
                                      color: Colors.white, size: 19),
                                ),
                              ],
                            ),
                            const SizedBox(height: 7),
                            Text(
                              kind.subtitle,
                              maxLines: scale > 1.4 ? 3 : 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Color(0xEDFFFFFF),
                                fontSize: 13,
                                height: 1.4,
                                shadows: [Shadow(color: Color(0x66000000), blurRadius: 7)],
                              ),
                            ),
                            const Spacer(),
                            Text(
                              'TOQUE PARA CRIAR',
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.85),
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 1.0,
                                shadows: const [Shadow(color: Color(0x77000000), blurRadius: 6)],
                              ),
                            ),
                          ],
                        ),
                      ),
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

class _RecentCreation extends StatelessWidget {
  final OficinaKind kind;
  final String title;
  final String prompt;
  final String? imagePath;
  final bool hasImage;
  final VoidCallback onTap;

  const _RecentCreation({
    required this.kind,
    required this.title,
    required this.prompt,
    required this.imagePath,
    required this.hasImage,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final g = context.gama;
    final file = hasImage && imagePath != null ? File(imagePath!) : null;
    final color = kind.color(g);
    return SizedBox(
      width: 238,
      child: Material(
        color: g.surfaceCard,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: const BorderRadius.horizontal(
                  left: Radius.circular(16),
                ),
                child: SizedBox(
                  width: 92,
                  height: 178,
                  child: file != null
                      ? Image.file(
                          file,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) =>
                              _RecentFallback(kind: kind, color: color),
                        )
                      : _RecentFallback(kind: kind, color: color),
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(11),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        kind.label.toUpperCase(),
                        style: TextStyle(
                          color: color,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.8,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: g.textPrimary,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        prompt,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: g.textMuted,
                          fontSize: 12,
                          height: 1.3,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RecentFallback extends StatelessWidget {
  final OficinaKind kind;
  final Color color;
  const _RecentFallback({required this.kind, required this.color});

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          color.withValues(alpha: 0.45),
          color.withValues(alpha: 0.12),
          context.gama.surfaceElevated,
        ],
      ),
    ),
    child: Center(child: Icon(kind.icon, color: color, size: 30)),
  );
}
