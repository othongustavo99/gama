import 'package:flutter/material.dart';

import '../core/gama_colors.dart';
import 'gama_orb.dart';

/// Estado de uma resposta em andamento ou com erro.
///
/// A mensagem é anunciada uma única vez por leitores de tela. Os botões ficam
/// fora da região de anúncio, para permanecerem navegáveis pelo teclado.
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
    final statusLine = Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        ExcludeSemantics(
          child: isError
              ? Icon(
                  Icons.error_outline_rounded,
                  color: context.gama.error,
                  size: 18,
                )
              : const GamaOrb(size: 29),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Semantics(
            liveRegion: true,
            label: isError ? 'Erro: $label' : label,
            child: ExcludeSemantics(
              child: isError
                  ? Text(
                      label,
                      maxLines: 3,
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
          ),
        ),
      ],
    );

    final actions = <Widget>[
      if (onRetry != null)
        TextButton.icon(
          onPressed: onRetry,
          icon: const Icon(Icons.refresh_rounded, size: 16),
          label: const Text('Tentar novamente'),
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            minimumSize: const Size(48, 48),
          ),
        ),
      if (onContinue != null)
        TextButton(
          onPressed: onContinue,
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            minimumSize: const Size(48, 48),
          ),
          child: const Text('Continuar'),
        ),
    ];
    if (actions.isEmpty) return statusLine;

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 335 ||
            MediaQuery.textScalerOf(context).scale(14) > 18;
        if (compact) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              statusLine,
              const SizedBox(height: 4),
              Wrap(spacing: 4, runSpacing: 4, children: actions),
            ],
          );
        }
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(child: statusLine),
            const SizedBox(width: 6),
            ...actions,
          ],
        );
      },
    );
  }
}
