import 'package:flutter/material.dart';

import '../core/gama_colors.dart';

/// Creation modes offered by Oficina.
enum OficinaKind { imagem, video, programar }

extension OficinaKindX on OficinaKind {
  static OficinaKind? fromChatMode(String? value) {
    for (final kind in OficinaKind.values) {
      if (kind.chatMode == value) return kind;
    }
    return null;
  }

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

  Color color(GamaPalette palette) => switch (this) {
    OficinaKind.imagem => palette.accent,
    OficinaKind.video => palette.accentCool,
    OficinaKind.programar => palette.success,
  };

  String get shortDescription => switch (this) {
    OficinaKind.imagem => 'Descreva uma cena e veja ela nascer.',
    OficinaKind.video => 'Transforme uma ideia em movimento.',
    OficinaKind.programar => 'Tire seu projeto do papel, passo a passo.',
  };

  List<String> get examples => switch (this) {
    OficinaKind.imagem => const [
      'Uma casa na árvore ao pôr do sol',
      'Capa de livro em aquarela',
    ],
    OficinaKind.video => const [
      'Um café ganhando vida pela manhã',
      'Animação suave de uma paisagem',
    ],
    OficinaKind.programar => const [
      'Um app de hábitos com calendário',
      'Uma página de portfólio responsiva',
    ],
  };

  String get subtitle => switch (this) {
    OficinaKind.imagem => 'Crie, edite, transforme ou analise imagens.',
    OficinaKind.video =>
      'Gere, edite e transforme vídeos com suas referências.',
    OficinaKind.programar =>
      'Crie projetos, analise código e trabalhe com arquivos.',
  };

  String get emptyHeadline => 'Oficina · $label';

  String get emptySubtitle => switch (this) {
    OficinaKind.imagem => 'Crie, edite, transforme ou analise imagens.\nA Gama entende a intenção de cada pedido.',
    OficinaKind.video => 'Gere, edite e melhore vídeos.\nDescreva o que quer e anexe referências se precisar.',
    OficinaKind.programar => 'Código, análise e arquivos.\nCada mensagem é tratada como tarefa de criação.',
  };

  List<OficinaSuggestion> get emptySuggestions => switch (this) {
    OficinaKind.imagem => const [
      OficinaSuggestion(
        'Criar imagem',
        'Descreva a cena, estilo e detalhes.',
        Icons.image_outlined,
        'Crie uma imagem de: ',
      ),
      OficinaSuggestion(
        'Editar / melhorar',
        'Anexe a imagem e diga o que mudar.',
        Icons.auto_fix_high_outlined,
        'Melhore esta imagem anexada',
      ),
      OficinaSuggestion(
        'Analisar imagem',
        'Anexe a imagem para análise visual.',
        Icons.visibility_outlined,
        'Analise esta imagem e descreva o que vê',
      ),
    ],
    OficinaKind.video => const [
      OficinaSuggestion(
        'Gerar vídeo',
        'Descreva o vídeo, duração e estilo.',
        Icons.videocam_outlined,
        'Gere um vídeo de: ',
      ),
      OficinaSuggestion(
        'Editar vídeo',
        'Anexe o vídeo e diga a transformação.',
        Icons.content_cut_rounded,
        'Edite o vídeo anexado: ',
      ),
      OficinaSuggestion(
        'Melhorar vídeo',
        'Anexe o vídeo para melhorar a qualidade.',
        Icons.high_quality_outlined,
        'Melhore a qualidade deste vídeo',
      ),
    ],
    OficinaKind.programar => const [
      OficinaSuggestion(
        'Criar projeto',
        'Descreva a feature ou o app desejado.',
        Icons.code_rounded,
        'Crie um app Flutter que: ',
      ),
      OficinaSuggestion(
        'Auditoria profunda',
        'Anexe ZIP ou GitHub para análise por módulos.',
        Icons.fact_check_outlined,
        'Faça uma revisão profunda deste projeto: mostre cobertura real, arquivos não lidos, achados com evidências e prioridades. Não presuma que analisou o que ficou de fora.',
      ),
      OficinaSuggestion(
        'Corrigir e entregar ZIP',
        'Corrija arquivos e prepare o pacote verificável.',
        Icons.folder_zip_outlined,
        'Analise o projeto anexado, identifique erros concretos e me entregue em ZIP os arquivos completos corrigidos. Informe quais arquivos mudaram, cobertura, validações feitas e o que ainda não foi testado. Preserve as funções existentes.',
      ),
      OficinaSuggestion(
        'Refatorar',
        'Cole o trecho ou anexe os arquivos.',
        Icons.auto_awesome_outlined,
        'Refatore este código, explique as mudanças e não altere contratos públicos sem necessidade: ',
      ),
    ],
  };
}

class OficinaSuggestion {
  final String title;
  final String description;
  final IconData icon;
  final String prompt;

  const OficinaSuggestion(this.title, this.description, this.icon, this.prompt);
}
