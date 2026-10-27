import 'dart:ui';

import 'package:flutter/material.dart';

import '../core/gama_colors.dart';

/// Padrão de navegação sem AppBar: apenas os controles essenciais flutuam
/// sobre o fundo da tela.
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
        const Positioned(
          left: 0,
          right: 0,
          top: 0,
          child: IgnorePointer(child: GamaTopShade()),
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

/// Véu superior compartilhado com todas as telas de navegação flutuante.
/// A transição termina em transparência total: não cria uma faixa ou corte
/// horizontal quando o conteúdo é rolado sob os controles.
class GamaTopShade extends StatelessWidget {
  const GamaTopShade({super.key});

  @override
  Widget build(BuildContext context) {
    final palette = context.gama;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final height = MediaQuery.paddingOf(context).top + 148.0;
    final shade = Color.lerp(
      palette.background,
      isDark ? Colors.black : const Color(0xFFB8C0CC),
      isDark ? 0.42 : 0.20,
    )!;

    return ClipRect(
      child: SizedBox(
        height: height,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              stops: const [0.0, 0.30, 0.67, 1.0],
              colors: [
                shade.withValues(alpha: 0.97),
                shade.withValues(alpha: 0.84),
                shade.withValues(alpha: 0.34),
                shade.withValues(alpha: 0),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Contorno discreto aplicado ao botão flutuante.
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
        border: Border.all(color: palette.border.withValues(alpha: 0.58)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.18),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: ClipOval(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
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
