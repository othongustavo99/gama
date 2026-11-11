import 'package:flutter/material.dart';

/// Shared spacing, shape, elevation and motion values for Gama's interface.
abstract final class GamaSpace {
  static const double xxs = 2;
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 24;
  static const double xxxl = 32;
}

abstract final class GamaRadius {
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 24;
  static const double pill = 999;
}

abstract final class GamaMotion {
  static const Duration fast = Duration(milliseconds: 140);
  static const Duration standard = Duration(milliseconds: 220);
  static const Duration slow = Duration(milliseconds: 320);
  static const Curve curve = Curves.easeOutCubic;
}

abstract final class GamaElevation {
  static List<BoxShadow> card(Color color) => [
    BoxShadow(
      color: color.withValues(alpha: 0.10),
      blurRadius: 22,
      offset: const Offset(0, 8),
    ),
  ];
}


/// Escala semântica para telas e componentes compartilhados.
/// A escala de acessibilidade do sistema é aplicada pelo próprio Flutter.
abstract final class GamaType {
  static const double caption = 12;
  static const double label = 13;
  static const double secondary = 14;
  static const double body = 15;
  static const double section = 18;
  static const double heading = 22;

  static const TextStyle sectionTitle = TextStyle(
    fontSize: section,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.3,
    height: 1.2,
  );
  static const TextStyle description = TextStyle(
    fontSize: secondary,
    height: 1.45,
  );
}

abstract final class GamaHitTarget {
  /// Alvo de toque recomendado para botões com ícones.
  static const double minimum = 48;
}
