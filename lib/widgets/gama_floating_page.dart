import 'package:flutter/material.dart';

import '../core/gama_colors.dart';

/// Camada de controles sem AppBar: nenhuma superfície é desenhada atrás
/// da linha inteira. Apenas cada botão possui seu próprio fundo opaco.
///
/// Em páginas com rolagem, [contentBehindHeader] permite que os itens
/// continuem passando por trás do cabeçalho. A página deve reservar um
/// espaço inicial dentro da própria rolagem para os primeiros itens.
class GamaFloatingPage extends StatelessWidget {
  final Widget child;
  final List<Widget> actions;
  final Widget? leading;
  final bool showBack;
  final Widget? tabs;
  final bool contentBehindHeader;

  const GamaFloatingPage({
    super.key,
    required this.child,
    this.actions = const [],
    this.leading,
    this.showBack = true,
    this.tabs,
    this.contentBehindHeader = false,
  });

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    final headerInset = top + 70.0;

    // O corpo ocupa o espaço real da página. O inset de segurança é aplicado
    // somente onde necessário, não por uma faixa colorida de AppBar.
    final content = tabs != null
        ? Padding(
            padding: EdgeInsets.only(top: headerInset),
            child: Column(
              children: [
                tabs!,
                Expanded(child: child),
              ],
            ),
          )
        : contentBehindHeader
            ? child
            : Padding(
                padding: EdgeInsets.only(top: headerInset),
                child: child,
              );

    return Stack(
      fit: StackFit.expand,
      children: [
        content,
        // Somente sombra transparente, nunca fundo sólido ou barreira de toque.
        const Positioned(
          left: 0,
          right: 0,
          top: 0,
          child: IgnorePointer(child: GamaTopShade()),
        ),
        Positioned(
          left: 12,
          right: 12,
          top: top + 6,
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
              for (var i = 0; i < actions.length; i++) ...[
                if (i > 0) const SizedBox(width: 8),
                GamaFloatingControl(child: actions[i]),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// Sombra sutil, com alfa decrescente até zero: o conteúdo que passa
/// por trás permanece visível. Adapta-se ao tema atual.
class GamaTopShade extends StatelessWidget {
  const GamaTopShade({super.key});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final shadow = isDark ? Colors.black : const Color(0xFF18202D);
    final height = MediaQuery.paddingOf(context).top + 150.0;

    return SizedBox(
      height: height,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            stops: const [0.0, 0.30, 0.68, 1.0],
            colors: [
              shadow.withValues(alpha: isDark ? 0.32 : 0.13),
              shadow.withValues(alpha: isDark ? 0.20 : 0.075),
              shadow.withValues(alpha: isDark ? 0.055 : 0.02),
              shadow.withValues(alpha: 0),
            ],
          ),
        ),
      ),
    );
  }
}

/// Botão circular com fundo 100% sólido em qualquer tela ou tema.
/// A opacidade pertence ao botão; a barra inteira permanece transparente.
class GamaFloatingControl extends StatelessWidget {
  final Widget child;

  const GamaFloatingControl({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final palette = context.gama;
    return DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: palette.surfaceCard,
        border: Border.all(color: palette.border),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.23),
            blurRadius: 18,
            offset: const Offset(0, 7),
          ),
        ],
      ),
      child: ClipOval(
        child: Material(
          color: palette.surfaceCard,
          child: IconTheme(
            data: IconThemeData(color: palette.textPrimary, size: 22),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              child: Center(child: child),
            ),
          ),
        ),
      ),
    );
  }
}
