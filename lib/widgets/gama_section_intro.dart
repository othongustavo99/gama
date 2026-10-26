import 'package:flutter/material.dart';

import '../core/gama_colors.dart';
import '../core/design_tokens.dart';

/// Cabeçalho reutilizável para Biblioteca, Imagens e ferramentas.
/// Quebra linhas sem exigir largura fixa, inclusive com texto ampliado.
class GamaSectionIntro extends StatelessWidget {
  const GamaSectionIntro({
    super.key,
    required this.title,
    required this.description,
    required this.icon,
    this.compact = false,
  });

  final String title;
  final String description;
  final IconData icon;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final g = context.gama;
    return Semantics(
      header: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: compact ? 40 : 48,
            height: compact ? 40 : 48,
            decoration: BoxDecoration(
              color: g.accentSoft,
              borderRadius: BorderRadius.circular(GamaRadius.lg),
              border: Border.all(color: g.accent.withValues(alpha: 0.16)),
            ),
            child: Icon(icon, color: g.accent, size: compact ? 21 : 24),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title, style: TextStyle(
                  color: g.textPrimary,
                  fontSize: compact ? 16 : 19,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.35,
                )),
                const SizedBox(height: 3),
                Text(description, style: TextStyle(
                  color: g.textSecondary,
                  fontSize: compact ? 12 : 13,
                  height: 1.35,
                )),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
