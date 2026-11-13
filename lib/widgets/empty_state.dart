import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

import '../core/gama_colors.dart';
import '../services/identity_service.dart';
import 'gama_orb.dart';
import 'gama_cyberpunk_overlay.dart';
import '../models/oficina_kind.dart';
import '../services/attachment_service.dart';

enum EmptySuggestionAction {
  write,
  explain,
  brainstorm,
  summarizeAttachment,
  describeAttachment,
  analyzeAttachment,
  extractTasks,
  editAttachment,
  reviewProject,
  explainError,
  generateWidget,
}

class EmptyState extends StatelessWidget {
  final void Function(EmptySuggestionAction action, String text) onSuggestion;
  final OficinaKind? oficinaKind;
  final List<AttachmentKind> attachmentKinds;
  final ValueListenable<TextEditingValue>? draft;
  final double topInset;
  final double bottomInset;

  const EmptyState({
    super.key,
    required this.onSuggestion,
    required this.attachmentKinds,
    this.draft,
    this.oficinaKind,
    this.topInset = 0,
    this.bottomInset = 0,
  });

  AttachmentKind? get _attachmentKind =>
      attachmentKinds.isEmpty ? null : attachmentKinds.first;

  List<EmptySuggestionAction> get _activeActions {
    switch (oficinaKind) {
      case OficinaKind.imagem:
      case OficinaKind.video:
      case OficinaKind.programar:
        return const [
          EmptySuggestionAction.generateWidget,
          EmptySuggestionAction.explainError,
          EmptySuggestionAction.reviewProject,
        ];
      case null:
        return switch (_attachmentKind) {
          AttachmentKind.image => const [
            EmptySuggestionAction.describeAttachment,
            EmptySuggestionAction.analyzeAttachment,
            EmptySuggestionAction.editAttachment,
          ],
          AttachmentKind.video || AttachmentKind.audio => const [
            EmptySuggestionAction.summarizeAttachment,
            EmptySuggestionAction.analyzeAttachment,
            EmptySuggestionAction.extractTasks,
          ],
          _ when _attachmentKind != null => const [
            EmptySuggestionAction.summarizeAttachment,
            EmptySuggestionAction.analyzeAttachment,
            EmptySuggestionAction.extractTasks,
          ],
          _ => const [
            EmptySuggestionAction.write,
            EmptySuggestionAction.explain,
            EmptySuggestionAction.brainstorm,
          ],
        };
    }
  }

  List<String> get _activeSuggestions {
    switch (oficinaKind) {
      case OficinaKind.imagem:
      case OficinaKind.video:
      case OficinaKind.programar:
        return oficinaKind!.emptySuggestions
            .map((suggestion) => suggestion.prompt)
            .toList();
      case null:
        return switch (_attachmentKind) {
          AttachmentKind.image => [
            'Descrever a imagem',
            'Analisar os elementos',
            'Sugerir uma edição',
          ],
          AttachmentKind.video => [
            'Resumir o vídeo',
            'Analisar uma cena',
            'Listar os momentos principais',
          ],
          AttachmentKind.audio => [
            'Resumir o áudio',
            'Identificar os temas',
            'Extrair decisões e tarefas',
          ],
          _ when _attachmentKind != null => [
            'Resumir o arquivo',
            'Analisar o conteúdo',
            'Extrair pontos e tarefas',
          ],
          _ => ['Escrever um texto', 'Aprender algo novo', 'Pensar em ideias'],
        };
    }
  }

  List<String> get _activeTitles {
    switch (oficinaKind) {
      case OficinaKind.imagem:
      case OficinaKind.video:
      case OficinaKind.programar:
        return oficinaKind!.emptySuggestions
            .map((suggestion) => suggestion.title)
            .toList();
      case null:
        return switch (_attachmentKind) {
          AttachmentKind.image => ['Descrever', 'Analisar', 'Editar'],
          AttachmentKind.video => [
            'Resumir',
            'Analisar cena',
            'Momentos-chave',
          ],
          AttachmentKind.audio => ['Resumir', 'Temas', 'Decisões e tarefas'],
          _ when _attachmentKind != null => [
            'Resumir arquivo',
            'Analisar conteúdo',
            'Extrair tarefas',
          ],
          _ => ['Escrever', 'Explicar', 'Criar ideias'],
        };
    }
  }

  List<String> get _activeDescriptions {
    switch (oficinaKind) {
      case OficinaKind.imagem:
      case OficinaKind.video:
      case OficinaKind.programar:
        return oficinaKind!.emptySuggestions
            .map((suggestion) => suggestion.description)
            .toList();
      case null:
        return switch (_attachmentKind) {
          AttachmentKind.image => [
            'Descreva o que aparece ou peça detalhes visuais.',
            'Identifique elementos e relações na imagem.',
            'Diga como gostaria de transformar a imagem.',
          ],
          AttachmentKind.video => [
            'Receba um resumo do conteúdo enviado.',
            'Peça uma análise de uma cena específica.',
            'Encontre os principais momentos do vídeo.',
          ],
          AttachmentKind.audio => [
            'Receba um resumo do conteúdo falado.',
            'Entenda os assuntos discutidos.',
            'Liste decisões e ações mencionadas.',
          ],
          _ when _attachmentKind != null => [
            'Faça um resumo claro do arquivo enviado.',
            'Entenda o conteúdo e seus pontos importantes.',
            'Liste decisões, tópicos e próximos passos.',
          ],
          _ => [
            'Rascunhe uma mensagem, e-mail ou publicação.',
            'Peça uma explicação passo a passo.',
            'Explore possibilidades para um desafio.',
          ],
        };
    }
  }

  List<IconData> get _activeIcons {
    switch (oficinaKind) {
      case OficinaKind.imagem:
      case OficinaKind.video:
      case OficinaKind.programar:
        return oficinaKind!.emptySuggestions
            .map((suggestion) => suggestion.icon)
            .toList();
      case null:
        return switch (_attachmentKind) {
          AttachmentKind.image => [
            Icons.image_outlined,
            Icons.search_rounded,
            Icons.auto_fix_high_outlined,
          ],
          AttachmentKind.video => [
            Icons.movie_outlined,
            Icons.search_rounded,
            Icons.video_library_outlined,
          ],
          AttachmentKind.audio => [
            Icons.summarize_outlined,
            Icons.graphic_eq_rounded,
            Icons.checklist_rounded,
          ],
          _ when _attachmentKind != null => [
            Icons.summarize_outlined,
            Icons.manage_search,
            Icons.checklist_rounded,
          ],
          _ => [
            Icons.edit_note_rounded,
            Icons.lightbulb_outline_rounded,
            Icons.auto_awesome_rounded,
          ],
        };
    }
  }

  String get _headline {
    switch (oficinaKind) {
      case OficinaKind.imagem:
      case OficinaKind.video:
      case OficinaKind.programar:
        return oficinaKind!.emptyHeadline;
      case null:
        final hour = DateTime.now().hour;
        final hello = hour < 12
            ? 'Bom dia'
            : hour < 18
            ? 'Boa tarde'
            : 'Boa noite';
        final name = IdentityService.instance.displayName
            .trim()
            .split(' ')
            .first;
        return name.isEmpty || name.toLowerCase() == 'usuário'
            ? '$hello!'
            : '$hello, $name';
    }
  }

  String get _subtitle {
    switch (oficinaKind) {
      case OficinaKind.imagem:
      case OficinaKind.video:
      case OficinaKind.programar:
        return oficinaKind!.emptySubtitle;
      case null:
        return _attachmentKind != null
            ? 'Seu anexo está pronto. Escolha uma sugestão ou escreva seu pedido.'
            : 'Escolha um começo ou escreva o que você tem em mente.';
    }
  }

  String get _badge {
    switch (oficinaKind) {
      case OficinaKind.imagem:
        return 'MODO CRIAÇÃO · IMAGEM';
      case OficinaKind.video:
        return 'MODO CRIAÇÃO · VÍDEO';
      case OficinaKind.programar:
        return 'MODO CRIAÇÃO · CÓDIGO';
      case null:
        return 'CONVERSA';
    }
  }

  @override
  Widget build(BuildContext context) {
    if (context.gama.isCyberpunk) {
      return Padding(
        padding: EdgeInsets.only(top: topInset),
        child: LayoutBuilder(
          builder: (context, constraints) => Padding(
            padding: EdgeInsets.only(
              bottom: bottomInset.clamp(0.0, constraints.maxHeight).toDouble(),
            ),
            child: Align(
              alignment: const Alignment(0, -.22),
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 10, 24, 12),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _CyberpunkGreeting(
                        mode: _badge,
                        headline: _headline,
                        subtitle: _subtitle,
                      ),
                      const SizedBox(height: 17),
                      _draftSuggestions(context),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }
    // Sobe o conjunto da recepção sem alterar a caixa de mensagem.
    // O alinhamento adapta o deslocamento ao espaço livre: em telas
    // baixas o conteúdo continua rolável, sem corte dos atalhos.
    return Align(
      alignment: const Alignment(0, -0.50),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              GamaOrb(size: oficinaKind == null ? 128 : 106),
              const SizedBox(height: 22),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 11,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: context.gama.surfaceCard,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: context.gama.borderSoft),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.circle, color: context.gama.success, size: 7),
                    SizedBox(width: 7),
                    Text(
                      _badge,
                      style: TextStyle(
                        color: context.gama.textSecondary,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.0,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 15),
              Text(
                _headline,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: context.gama.textPrimary,
                  fontSize: 27,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.8,
                  height: 1.12,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                _subtitle,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: context.gama.textMuted,
                  fontSize: 14,
                  height: 1.55,
                ),
              ),
              const SizedBox(height: 27),
              _draftSuggestions(context),
            ],
          ),
        ),
      ),
    );
  }

  Widget _draftSuggestions(BuildContext context) {
    final currentDraft = draft;
    if (currentDraft == null) return _suggestionChips(context);
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: currentDraft,
      builder: (context, value, _) => value.text.trim().isEmpty
          ? _suggestionChips(context)
          : const SizedBox.shrink(),
    );
  }

  Widget _suggestionChips(BuildContext context) {
    final g = context.gama;
    final cyberpunk = g.isCyberpunk;
    final shape = cyberpunk
        ? gamaCyberpunkBorder(cut: 11, side: BorderSide(color: g.border))
        : RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: g.borderSoft),
          );
    final titles = _activeTitles;
    final icons = _activeIcons;
    final descriptions = _activeDescriptions;
    final suggestions = _activeSuggestions;
    final actions = _activeActions;
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 510;
        final tileWidth = wide
            ? (constraints.maxWidth - 20) / 3
            : constraints.maxWidth;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 11),
              child: Text(
                'PARA COMEÇAR',
                textAlign: wide || cyberpunk
                    ? TextAlign.left
                    : TextAlign.center,
                style: TextStyle(
                  color: cyberpunk ? g.accentBright : g.textMuted,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.0,
                ),
              ),
            ),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              alignment: WrapAlignment.center,
              children: [
                for (var i = 0; i < suggestions.length; i++)
                  SizedBox(
                    width: tileWidth,
                    child: Material(
                      color: g.surfaceCard,
                      shape: shape,
                      clipBehavior: cyberpunk ? Clip.antiAlias : Clip.none,
                      child: InkWell(
                        customBorder: shape,
                        onTap: () => onSuggestion(actions[i], suggestions[i]),
                        child: Padding(
                          padding: const EdgeInsets.all(13),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              Icon(icons[i], size: 21, color: g.accent),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      titles[i],
                                      style: TextStyle(
                                        color: g.textPrimary,
                                        fontWeight: FontWeight.w700,
                                        fontSize: 13,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      descriptions[i],
                                      maxLines: wide ? 3 : 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: g.textSecondary,
                                        fontSize: 12,
                                        height: 1.4,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              if (cyberpunk && !wide)
                                Icon(
                                  Icons.chevron_right,
                                  color: g.accentMuted,
                                  size: 18,
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        );
      },
    );
  }
}

class _CyberpunkGreeting extends StatelessWidget {
  const _CyberpunkGreeting({
    required this.mode,
    required this.headline,
    required this.subtitle,
  });

  final String mode;
  final String headline;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final palette = context.gama;
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: palette.surface,
        shape: gamaCyberpunkBorder(
          cut: 19,
          side: BorderSide(color: palette.border),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 13),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                ExcludeSemantics(
                  child: DecoratedBox(
                    decoration: ShapeDecoration(
                      color: palette.accent,
                      shape: gamaCyberpunkBorder(cut: 10),
                    ),
                    child: SizedBox.square(
                      dimension: 46,
                      child: CustomPaint(
                        painter: _GammaMarkPainter(palette.onAccent),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'GAMMA / $mode',
                    style: TextStyle(
                      color: palette.accentBright,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.35,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 13),
            Semantics(
              header: true,
              child: Text(
                headline,
                style: TextStyle(
                  color: palette.textPrimary,
                  fontSize: 29,
                  height: 1.12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -.7,
                ),
              ),
            ),
            const SizedBox(height: 7),
            Text(
              subtitle,
              style: TextStyle(
                color: palette.textSecondary,
                fontSize: 14,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 13),
            const SizedBox(
              width: double.infinity,
              child: GamaCyberpunkHeaderRule(),
            ),
          ],
        ),
      ),
    );
  }
}

class _GammaMarkPainter extends CustomPainter {
  const _GammaMarkPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    canvas.drawPath(
      Path()
        ..moveTo(15, 34)
        ..lineTo(15, 17)
        ..lineTo(20, 12)
        ..lineTo(33, 12)
        ..moveTo(20, 30)
        ..lineTo(20, 19)
        ..lineTo(23, 16)
        ..lineTo(30, 16),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _GammaMarkPainter oldDelegate) =>
      oldDelegate.color != color;
}
