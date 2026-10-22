import 'package:flutter/material.dart';

import '../core/gama_colors.dart';
import 'gama_orb.dart';

/// Status curto dentro do balão da Gama, com semântica para leitores de tela.
class ChatStatusIndicator extends StatelessWidget {
  final String label;
  final bool isError;
  final VoidCallback? onRetry;
  final VoidCallback? onContinue;

  const ChatStatusIndicator({
    super.key,
    required this.label,
    this.isError = false,
    this.onRetry,
    this.onContinue,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (isError)
            Icon(
              Icons.error_outline_rounded,
              color: context.gama.error,
              size: 16,
            )
          else
            const GamaOrb(size: 29),
          const SizedBox(width: 8),
          Flexible(
            child: isError
                ? Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: context.gama.error,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  )
                : GamaShimmerText(
                    text: label,
                    style: TextStyle(
                      color: context.gama.textMuted,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      height: 1.3,
                    ),
                  ),
          ),
          if (onRetry != null) ...[
            const SizedBox(width: 6),
            TextButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded, size: 16),
              label: const Text('Tentar novamente'),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                minimumSize: const Size(48, 48),
              ),
            ),
          ],
          if (onContinue != null) ...[
            const SizedBox(width: 4),
            TextButton(
              onPressed: onContinue,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                minimumSize: const Size(48, 48),
              ),
              child: const Text('Continuar'),
            ),
          ],
        ],
      ),
    );
  }
}
