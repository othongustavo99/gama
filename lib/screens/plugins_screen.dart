import 'package:flutter/material.dart';

import '../core/gama_colors.dart';

class PluginsScreen extends StatelessWidget {
  const PluginsScreen({super.key});

  static const _items = [
    ('Busca na web', 'Respostas com fontes quando necessário', true),
    ('Memória por usuário', 'Fatos salvos e sincronizados no servidor', true),
    ('Anexos', 'Imagens, PDF, ZIP e código no chat', true),
    ('Visão', 'Análise de imagem quando você anexa foto', true),
    ('Agendamentos', 'Lembretes automáticos', false),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: GamaColors.background,
      appBar: AppBar(
        backgroundColor: GamaColors.surface,
        title: const Text('Plugins'),
      ),
      body: ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: _items.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (_, i) {
          final (title, subtitle, on) = _items[i];
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: GamaColors.surfaceCard,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: GamaColors.border),
            ),
            child: Row(
              children: [
                Icon(
                  on ? Icons.extension_rounded : Icons.extension_outlined,
                  color: on ? GamaColors.accent : GamaColors.textMuted,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          color: GamaColors.textPrimary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: const TextStyle(
                          color: GamaColors.textMuted,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: on
                        ? GamaColors.accentSoft
                        : GamaColors.surfaceElevated,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    on ? 'Ativo' : 'Em breve',
                    style: TextStyle(
                      color: on ? GamaColors.accent : GamaColors.textMuted,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
