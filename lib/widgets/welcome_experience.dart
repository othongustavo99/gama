import 'package:flutter/material.dart';

import '../core/gama_colors.dart';

/// Apresentação leve da Gamma, sem onboarding obrigatório e sem chamadas de rede.
/// O usuário pode dispensar e reabrir pelo menu lateral.
enum GamaWelcomeAction { conversar, oficina, biblioteca }

class GamaWelcomeExperience extends StatelessWidget {
  const GamaWelcomeExperience({super.key});

  static Future<GamaWelcomeAction?> show(BuildContext context) {
    return showModalBottomSheet<GamaWelcomeAction>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: context.gama.surface,
      constraints: const BoxConstraints(maxWidth: 600),
      builder: (sheetContext) => const GamaWelcomeExperience(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.gama;
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 26),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: colors.accentSoft,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(Icons.auto_awesome_rounded, color: colors.accent, size: 23),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Bem-vindo à Gamma', style: TextStyle(
                        color: colors.textPrimary,
                        fontSize: 21,
                        fontWeight: FontWeight.w700,
                      )),
                      const SizedBox(height: 3),
                      Text('Sua assistente para conversar, criar e trabalhar.',
                        style: TextStyle(color: colors.textSecondary, fontSize: 13)),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 22),
            Text('O que você gostaria de fazer?', style: TextStyle(
              color: colors.textPrimary,
              fontSize: 15,
              fontWeight: FontWeight.w700,
            )),
            const SizedBox(height: 10),
            _WelcomeChoice(
              icon: Icons.chat_bubble_outline_rounded,
              title: 'Conversar e aprender',
              description: 'Faça perguntas, peça ajuda com textos e explore ideias.',
              onTap: () => Navigator.pop(context, GamaWelcomeAction.conversar),
            ),
            const SizedBox(height: 9),
            _WelcomeChoice(
              icon: Icons.handyman_outlined,
              title: 'Criar na Oficina',
              description: 'Acesse as ferramentas de imagens, vídeos e programação.',
              onTap: () => Navigator.pop(context, GamaWelcomeAction.oficina),
            ),
            const SizedBox(height: 9),
            _WelcomeChoice(
              icon: Icons.folder_open_outlined,
              title: 'Encontrar minhas entregas',
              description: 'Consulte arquivos e tarefas disponíveis na Biblioteca.',
              onTap: () => Navigator.pop(context, GamaWelcomeAction.biblioteca),
            ),
            const SizedBox(height: 17),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline_rounded, size: 17, color: colors.textMuted),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Respostas de IA podem conter erros. Confira informações importantes. '
                    'Você pode revisar a memória e seus dados nas Configurações.',
                    style: TextStyle(color: colors.textMuted, fontSize: 12, height: 1.5),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Agora não'),
            ),
          ],
        ),
      ),
    );
  }
}

class _WelcomeChoice extends StatelessWidget {
  const _WelcomeChoice({
    required this.icon,
    required this.title,
    required this.description,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String description;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.gama;
    return Material(
      color: colors.surfaceCard,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: colors.borderSoft),
          ),
          child: Row(
            children: [
              Icon(icon, color: colors.accent, size: 23),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: TextStyle(
                      color: colors.textPrimary, fontSize: 14, fontWeight: FontWeight.w700,
                    )),
                    const SizedBox(height: 3),
                    Text(description, style: TextStyle(
                      color: colors.textSecondary, fontSize: 12, height: 1.4,
                    )),
                  ],
                ),
              ),
              const SizedBox(width: 5),
              Icon(Icons.chevron_right_rounded, color: colors.textMuted),
            ],
          ),
        ),
      ),
    );
  }
}
