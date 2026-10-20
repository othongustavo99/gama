import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../core/gama_colors.dart';
import '../services/conversation_service.dart';
import 'chat_screen.dart';
import '../widgets/app_drawer.dart';
import 'images_screen.dart';
import 'library_screen.dart';
import 'plugins_screen.dart';
import 'projects_screen.dart';
import 'scheduled_screen.dart';

/// Tipos de criação da Oficina.
enum OficinaKind { imagem, video, programar }

extension OficinaKindX on OficinaKind {
  String get label => switch (this) {
    OficinaKind.imagem => 'Imagem',
    OficinaKind.video => 'Vídeo',
    OficinaKind.programar => 'Programar',
  };

  String get chatMode => switch (this) {
    OficinaKind.imagem => 'oficina_imagem',
    OficinaKind.video => 'oficina_video',
    OficinaKind.programar => 'oficina_programar',
  };

  String get conversationTitle => 'Oficina · $label';

  IconData get icon => switch (this) {
    OficinaKind.imagem => Icons.image_outlined,
    OficinaKind.video => Icons.videocam_outlined,
    OficinaKind.programar => Icons.code_rounded,
  };

  String get subtitle => switch (this) {
    OficinaKind.imagem =>
      'Criar, editar, melhorar e analisar imagens com a skill de imagem.',
    OficinaKind.video =>
      'Gerar, editar e transformar vídeos com a skill de vídeo.',
    OficinaKind.programar =>
      'Código, análise, refatoração e arquivos — modelo GLM Flash.',
  };
}

/// Hub da Oficina: visual alinhado à chat screen, com 3 caminhos de criação.
class OficinaScreen extends StatelessWidget {
  const OficinaScreen({super.key});

  Future<void> _openKind(BuildContext context, OficinaKind kind) async {
    final conv = await ConversationService.instance.createConversation(
      title: kind.conversationTitle,
    );
    if (!context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _OficinaScaffold(
          child: ChatScreen(
            conversationId: conv.id,
            oficinaKind: kind,
            persistentSidebar: defaultTargetPlatform == TargetPlatform.windows,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final g = context.gama;

    return _OficinaScaffold(
      title: 'Oficina',
      child: ColoredBox(
        color: g.background,
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 28, 20, 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(
                children: [
                  Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      color: g.surfaceCard,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.22),
                        width: 1.2,
                      ),
                    ),
                    child: Icon(
                      Icons.handyman_rounded,
                      size: 34,
                      color: Colors.white.withValues(alpha: 0.88),
                    ),
                  ),
                  const SizedBox(height: 22),
                  Text(
                    'Modo criação',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: g.textPrimary,
                      fontSize: 24,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.6,
                      height: 1.15,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Escolha o que você quer criar.\nA Gama entra em foco total naquela skill.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: g.textMuted,
                      fontSize: 14,
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 28),
                  ...OficinaKind.values.map(
                    (kind) => Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: _OficinaCard(
                        kind: kind,
                        onTap: () => _openKind(context, kind),
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
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));
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
  final VoidCallback onTap;

  const _OficinaCard({required this.kind, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final g = context.gama;

    return Material(
      color: g.surfaceCard,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        splashColor: Colors.white.withValues(alpha: 0.06),
        highlightColor: Colors.white.withValues(alpha: 0.03),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.18),
              width: 1.1,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: g.surfaceElevated,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.12),
                  ),
                ),
                child: Icon(
                  kind.icon,
                  color: Colors.white.withValues(alpha: 0.9),
                  size: 22,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      kind.label,
                      style: TextStyle(
                        color: g.textPrimary,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      kind.subtitle,
                      style: TextStyle(
                        color: g.textSecondary,
                        fontSize: 12.5,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.arrow_forward_ios_rounded,
                size: 14,
                color: g.textMuted,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
