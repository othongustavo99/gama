import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

import '../core/gama_colors.dart';
import '../services/identity_service.dart';
import 'gama_orb.dart';
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

  const EmptyState({
    super.key,
    required this.onSuggestion,
    required this.attachmentKinds,
    this.draft,
    this.oficinaKind,
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
              if (draft == null)
                _suggestionChips(context)
              else
                ValueListenableBuilder<TextEditingValue>(
                  valueListenable: draft!,
                  builder: (context, value, _) => value.text.trim().isEmpty
                      ? _suggestionChips(context)
                      : const SizedBox.shrink(),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _suggestionChips(BuildContext context) {
    final g = context.gama;
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
                textAlign: wide ? TextAlign.left : TextAlign.center,
                style: TextStyle(
                  color: g.textMuted,
                  fontSize: 11,
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
                for (var i = 0; i < _activeSuggestions.length; i++)
                  SizedBox(
                    width: tileWidth,
                    child: Material(
                      color: g.surfaceCard,
                      borderRadius: BorderRadius.circular(16),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(16),
                        onTap: () => onSuggestion(
                          _activeActions[i], _activeSuggestions[i]),
                        child: Container(
                          padding: const EdgeInsets.all(13),
                          decoration: BoxDecoration(
                            border: Border.all(color: g.borderSoft),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              Icon(_activeIcons[i], size: 21, color: g.accent),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(_activeTitles[i], style: TextStyle(
                                      color: g.textPrimary,
                                      fontWeight: FontWeight.w700,
                                      fontSize: 13,
                                    )),
                                    const SizedBox(height: 4),
                                    Text(_activeDescriptions[i],
                                      maxLines: wide ? 3 : 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: g.textSecondary,
                                        fontSize: 11,
                                        height: 1.4,
                                      ),
                                    ),
                                  ],
                                ),
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
