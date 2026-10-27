import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Pintura opaca sob os controles de navegação do Android em edge-to-edge.
///
/// No Android com targetSdk 36, mudar apenas systemNavigationBarColor não
/// funciona. Essa camada usa a área de navegação fornecida pelo sistema,
/// mantendo todo o topo (status bar) transparente como já estava.
class GamaNavigationBarSurface extends StatelessWidget {
  final Widget child;

  const GamaNavigationBarSurface({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return child;
    }

    final media = MediaQuery.of(context);
    final bottomInset = media.padding.bottom;

    // Quando o teclado está aberto, o Android controla sua própria área
    // inferior: não sobrepor uma faixa sobre o teclado ou o campo de texto.
    if (bottomInset <= 0 || media.viewInsets.bottom > 0) {
      return child;
    }

    final solidBackground = Theme.of(context).scaffoldBackgroundColor;
    return Stack(
      fit: StackFit.expand,
      children: [
        child,
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: bottomInset,
          child: IgnorePointer(
            child: ExcludeSemantics(
              child: ColoredBox(color: solidBackground),
            ),
          ),
        ),
      ],
    );
  }
}
