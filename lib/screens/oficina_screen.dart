import 'package:flutter/material.dart';

import '../core/gama_colors.dart';
import '../services/conversation_service.dart';
import 'chat_screen.dart';

/// Tipos de criação da Oficina.
enum OficinaKind {
  imagem,
  video,
  programar,
}

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
        builder: (_) => ChatScreen(
          conversationId: conv.id,
          oficinaKind: kind,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final g = context.gama;

    return Scaffold(
      backgroundColor: g.background,
      appBar: AppBar(
        backgroundColor: g.surface,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_rounded, color: g.textPrimary),
          onPressed: () => Navigator.of(context).pop(),
          tooltip: 'Voltar',
        ),
        title: Text(
          'Oficina',
          style: TextStyle(
            color: g.textPrimary,
            fontWeight: FontWeight.w700,
            fontSize: 18,
            letterSpacing: 0.2,
          ),
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: g.borderSoft),
        ),
      ),
      body: SafeArea(
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
                    'Escolha o que você quer criar.\n'
                    'A Gama entra em foco total naquela skill.',
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
                child: Icon(kind.icon, color: Colors.white.withValues(alpha: 0.9), size: 22),
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
