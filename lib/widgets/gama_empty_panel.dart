import 'package:flutter/material.dart';

import '../core/design_tokens.dart';
import '../core/gama_colors.dart';

/// Estado vazio padronizado e adaptável, sem alterar navegação/arquivos.
class GamaEmptyPanel extends StatelessWidget {
  const GamaEmptyPanel({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String description;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final g = context.gama;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 62,
                height: 62,
                decoration: BoxDecoration(
                  color: g.accentSoft,
                  borderRadius: BorderRadius.circular(GamaRadius.xl),
                ),
                child: Icon(icon, color: g.accent, size: 29),
              ),
              const SizedBox(height: 16),
              Text(title,
                textAlign: TextAlign.center,
                style: TextStyle(color: g.textPrimary, fontSize: 17,
                  fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 9),
              Text(description,
                textAlign: TextAlign.center,
                style: TextStyle(color: g.textSecondary, fontSize: 13, height: 1.5),
              ),
              if (actionLabel != null && onAction != null) ...[
                const SizedBox(height: 18),
                OutlinedButton(onPressed: onAction, child: Text(actionLabel!)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
