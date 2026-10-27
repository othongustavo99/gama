import 'package:flutter/material.dart';

import '../core/gama_colors.dart';

/// Padrão de navegação sem AppBar: apenas os controles essenciais flutuam
/// sobre o fundo da tela. O conteúdo permanece abaixo dos controles, de
/// modo que listas, formulários e acessibilidade não sofram sobreposição.
class GamaFloatingPage extends StatelessWidget {
  final Widget child;
  final List<Widget> actions;
  final Widget? leading;
  final bool showBack;
  final Widget? tabs;

  const GamaFloatingPage({
    super.key,
    required this.child,
    this.actions = const [],
    this.leading,
    this.showBack = true,
    this.tabs,
  });

  @override
  Widget build(BuildContext context) {
    final safeTop = MediaQuery.paddingOf(context).top;
    return Stack(
      children: [
        Positioned.fill(
          child: Padding(
            padding: EdgeInsets.only(top: safeTop + 62),
            child: tabs == null
                ? child
                : Column(
                    children: [
                      tabs!,
                      Expanded(child: child),
                    ],
                  ),
          ),
        ),
        Positioned(
          left: 12,
          right: 12,
          top: safeTop + 6,
          child: Row(
            children: [
              if (leading != null)
                GamaFloatingControl(child: leading!)
              else if (showBack)
                GamaFloatingControl(
                  child: IconButton(
                    tooltip: 'Voltar',
                    icon: const Icon(Icons.arrow_back_rounded),
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                ),
              const Spacer(),
              for (final action in actions) ...[
                if (actions.length > 1) const SizedBox(width: 7),
                GamaFloatingControl(child: action),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// Contorno discreto aplicado apenas ao botão, nunca à barra inteira.
class GamaFloatingControl extends StatelessWidget {
  final Widget child;

  const GamaFloatingControl({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final palette = context.gama;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: palette.surfaceCard.withValues(alpha: 0.94),
        border: Border.all(color: palette.border.withValues(alpha: 0.65)),
        borderRadius: BorderRadius.circular(15),
      ),
      child: IconTheme(
        data: IconThemeData(color: palette.textPrimary, size: 22),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 46, minHeight: 46),
          child: Center(child: child),
        ),
      ),
    );
  }
}
