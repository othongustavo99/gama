import 'package:flutter/material.dart';

import '../core/gama_colors.dart';
import '../models/oficina_kind.dart';
import '../services/attachment_service.dart';

enum EmptySuggestionAction {
  write,
  explain,
  brainstorm,
  summarizeAttachment,
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

  const EmptyState({
    super.key,
    required this.onSuggestion,
    required this.attachmentKinds,
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
            EmptySuggestionAction.analyzeAttachment,
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
        return 'Sua assistente virtual';
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
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 28, 24, 32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 94,
                height: 94,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      context.gama.surfaceHover,
                      context.gama.surfaceCard,
                    ],
                  ),
                  borderRadius: BorderRadius.circular(30),
                  border: Border.all(color: context.gama.border),
                  boxShadow: [
                    BoxShadow(
                      color: context.gama.accent.withValues(alpha: 0.12),
                      blurRadius: 36,
                      spreadRadius: 2,
                    ),
                  ],
                ),
                child: oficinaKind == null
                    ? Image.asset(
                        'assets/images/image3.png',
                        fit: BoxFit.contain,
                      )
                    : Hero(
                        tag: 'oficina-icon-${oficinaKind!.chatMode}',
                        child: Icon(
                          oficinaKind!.icon,
                          size: 52,
                          color: oficinaKind!.color(context.gama),
                        ),
                      ),
              ),
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
                  fontSize: 26,
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
              ..._activeSuggestions.asMap().entries.map((entry) {
                final index = entry.key;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Material(
                    color: context.gama.surfaceCard,
                    borderRadius: BorderRadius.circular(18),
                    child: InkWell(
                      onTap: () =>
                          onSuggestion(_activeActions[index], entry.value),
                      borderRadius: BorderRadius.circular(18),
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.fromLTRB(13, 13, 14, 13),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(color: context.gama.borderSoft),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 42,
                              height: 42,
                              decoration: BoxDecoration(
                                color: context.gama.accentSoft,
                                borderRadius: BorderRadius.circular(13),
                              ),
                              child: Icon(
                                _activeIcons[index],
                                color: context.gama.accentBright,
                                size: 20,
                              ),
                            ),
                            const SizedBox(width: 13),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    _activeTitles[index],
                                    style: TextStyle(
                                      color: context.gama.textPrimary,
                                      fontSize: 13.5,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    _activeDescriptions[index],
                                    style: TextStyle(
                                      color: context.gama.textMuted,
                                      fontSize: 12,
                                      height: 1.35,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Icon(
                              Icons.arrow_forward_rounded,
                              color: context.gama.textMuted,
                              size: 18,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              }),
            ],
          ),
        ),
      ),
    );
  }
}
