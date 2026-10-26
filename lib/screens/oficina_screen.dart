import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/local_account_scope.dart';

import '../core/gama_page_route.dart';
import '../core/gama_colors.dart';
import '../core/design_tokens.dart';
import '../models/conversation.dart';
import '../models/oficina_kind.dart';
import '../services/conversation_service.dart';
import 'chat_screen.dart';
import '../widgets/app_drawer.dart';
import 'images_screen.dart';
import 'library_screen.dart';
import 'plugins_screen.dart';
import 'projects_screen.dart';
import 'scheduled_screen.dart';
import '../utils/error_logger.dart';

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
      return (jsonDecode(raw) as List)
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList()
          .reversed
          .toList();
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
            persistentSidebar: defaultTargetPlatform == TargetPlatform.windows,
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
            persistentSidebar: defaultTargetPlatform == TargetPlatform.windows,
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
          builder: (context, _) {
            final desktop = defaultTargetPlatform == TargetPlatform.windows;
            final columns = desktop ? 3 : 1;
            final conversations = [
              ...ConversationService.instance.pinnedConversations,
              ...ConversationService.instance.recentConversations,
            ]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
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
                      padding: const EdgeInsets.fromLTRB(24, 30, 24, 20),
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
                            const SizedBox(height: 18),
                            Text(
                              'Modo criação',
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
                              'Escolha um caminho e comece com uma ideia.',
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
                          mainAxisExtent: desktop ? 300 : 290,
                        ),
                        delegate: SliverChildBuilderDelegate((context, index) {
                          final kind = OficinaKind.values[index];
                          return _OficinaCard(
                            kind: kind,
                            staggerIndex: index,
                            onTap: () => _openKind(context, kind),
                            onPrompt: (prompt) =>
                                _openKind(context, kind, prompt: prompt),
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
class _OficinaScaffold extends StatelessWidget {
  final Widget child;
  final String? title;

  const _OficinaScaffold({required this.child, this.title});

  bool get _desktop => defaultTargetPlatform == TargetPlatform.windows;

  @override
  Widget build(BuildContext context) {
    final desktop = _desktop;
    final service = ConversationService.instance;
    final drawer = AppDrawer(
      persistent: desktop,
      onNewChat: () async {
        await service.openFreshConversation();
        if (context.mounted) _returnToHome(context, desktop);
      },
      onSelectConversation: (id) async {
        await service.selectConversation(id);
        if (context.mounted) _returnToHome(context, desktop);
      },
      onOpenImages: () => _open(context, const ImagesScreen(), desktop),
      onOpenLibrary: () => _open(context, const LibraryScreen(), desktop),
      onOpenProjects: () => _open(context, const ProjectsScreen(), desktop),
      onOpenScheduled: () => _open(context, const ScheduledScreen(), desktop),
      onOpenPlugins: () => _open(context, const PluginsScreen(), desktop),
      onOpenOficina: () {
        if (title != null) {
          if (!desktop) Navigator.pop(context);
          return;
        }
        _open(context, const OficinaScreen(), desktop);
      },
    );

    final content = Builder(
      // O drawer móvel pertence ao Scaffold externo; o AppBar usa um Scaffold
      // interno. Este contexto alcança o drawer correto.
      builder: (drawerContext) => title == null
          ? child
          : Scaffold(
              backgroundColor: context.gama.background,
              appBar: AppBar(
                backgroundColor: context.gama.surface,
                elevation: 0,
                surfaceTintColor: Colors.transparent,
                leading: Builder(
                  builder: (ctx) => IconButton(
                    tooltip: 'Abrir conversas',
                    icon: Icon(
                      desktop ? Icons.arrow_back_rounded : Icons.menu_rounded,
                      color: context.gama.textPrimary,
                    ),
                    onPressed: () => desktop
                        ? Navigator.of(context).pop()
                        : Scaffold.of(drawerContext).openDrawer(),
                  ),
                ),
                title: Text(
                  title!,
                  style: TextStyle(
                    color: context.gama.textPrimary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              body: child,
            ),
    );

    return Scaffold(
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
    );
  }

  void _open(BuildContext context, Widget screen, bool desktop) {
    if (!desktop) Navigator.pop(context);
    Navigator.of(context).push(GamaPageRoute<void>(builder: (_) => screen));
  }

  /// Sai das rotas temporárias da Oficina para o chat principal. Com isso, a
  /// seleção da conversa atualizada pelo ConversationService aparece no Home.
  void _returnToHome(BuildContext context, bool desktop) {
    if (!desktop) Navigator.of(context).pop(); // fecha o drawer
    Navigator.of(context).popUntil((route) => route.isFirst);
  }
}

class _OficinaCard extends StatelessWidget {
  final OficinaKind kind;
  final int staggerIndex;
  final VoidCallback onTap;
  final ValueChanged<String> onPrompt;

  const _OficinaCard({
    required this.kind,
    required this.staggerIndex,
    required this.onTap,
    required this.onPrompt,
  });

  @override
  Widget build(BuildContext context) => _AnimatedOficinaCard(
    kind: kind,
    staggerIndex: staggerIndex,
    onTap: onTap,
    onPrompt: onPrompt,
  );
}

class _AnimatedOficinaCard extends StatefulWidget {
  final OficinaKind kind;
  final int staggerIndex;
  final VoidCallback onTap;
  final ValueChanged<String> onPrompt;

  const _AnimatedOficinaCard({
    required this.kind,
    required this.staggerIndex,
    required this.onTap,
    required this.onPrompt,
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
    final g = context.gama;
    final kind = widget.kind;
    final color = kind.color(g);

    return AnimatedOpacity(
      opacity: _visible ? 1 : 0,
      duration: const Duration(milliseconds: 360),
      curve: Curves.easeOut,
      child: AnimatedSlide(
        offset: _visible ? Offset.zero : const Offset(0, 0.08),
        duration: const Duration(milliseconds: 360),
        curve: Curves.easeOutCubic,
        child: AnimatedScale(
          scale: _pressed ? 0.98 : 1,
          duration: const Duration(milliseconds: 110),
          curve: Curves.easeOut,
          child: Material(
            color: g.surfaceCard,
            borderRadius: BorderRadius.circular(20),
            child: InkWell(
              onTap: widget.onTap,
              onTapDown: (_) => setState(() => _pressed = true),
              onTapCancel: () => setState(() => _pressed = false),
              onTapUp: (_) => setState(() => _pressed = false),
              borderRadius: BorderRadius.circular(20),
              splashColor: color.withValues(alpha: 0.09),
              highlightColor: color.withValues(alpha: 0.05),
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: g.border),
                  boxShadow: GamaElevation.card(color),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Hero(
                      tag: 'oficina-icon-${kind.chatMode}',
                      child: Container(
                        width: 54,
                        height: 54,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              color.withValues(alpha: 0.24),
                              color.withValues(alpha: 0.07),
                            ],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: color.withValues(alpha: 0.28),
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: color.withValues(alpha: 0.18),
                              blurRadius: 18,
                              spreadRadius: 1,
                            ),
                          ],
                        ),
                        child: Icon(kind.icon, size: 27, color: color),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      kind.label,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: g.textPrimary,
                        fontSize: 19,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      kind.shortDescription,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      style: TextStyle(
                        color: g.textSecondary,
                        fontSize: 13.5,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        for (var i = 0; i < kind.examples.length; i++) ...[
                          if (i > 0) const SizedBox(height: 7),
                          ActionChip(
                            label: Text(
                              kind.examples[i],
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            onPressed: () => widget.onPrompt(kind.examples[i]),
                            backgroundColor: color.withValues(alpha: 0.08),
                            side: BorderSide(
                              color: color.withValues(alpha: 0.22),
                            ),
                            labelStyle: TextStyle(
                              color: g.textSecondary,
                              fontSize: 11,
                            ),
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          'Abrir modo',
                          style: TextStyle(
                            color: color,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Icon(
                          Icons.arrow_forward_rounded,
                          size: 18,
                          color: color,
                        ),
                      ],
                    ),
                  ],
                ),
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
  final VoidCallback onTap;

  const _RecentCreation({
    required this.kind,
    required this.title,
    required this.prompt,
    required this.imagePath,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final g = context.gama;
    final file = imagePath == null ? null : File(imagePath!);
    final hasImage = file != null && file.existsSync();
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
                  child: hasImage
                      ? Image.file(
                          file!,
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
                          fontSize: 9,
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
                          fontSize: 10.5,
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
