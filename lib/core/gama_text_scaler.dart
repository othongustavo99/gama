import 'package:flutter/painting.dart';

/// Combina a preferência de tamanho da Gamma com a escala nativa do sistema.
/// Não transforma a curva não linear do Android em um multiplicador fixo.
class GamaUserTextScaler extends TextScaler {
  const GamaUserTextScaler(this.system, this.preference);

  final TextScaler system;
  final double preference;

  @override
  double scale(double fontSize) => system.scale(fontSize * preference);

  // Compatibilidade com componentes Flutter que ainda consultam este getter.
  @override
  double get textScaleFactor => system.textScaleFactor * preference;

  @override
  bool operator ==(Object other) =>
      other is GamaUserTextScaler &&
      other.system == system &&
      other.preference == preference;

  @override
  int get hashCode => Object.hash(system, preference);
}

TextScaler gamaEffectiveTextScaler(TextScaler system, double preference) {
  if (preference == 1.0) return system;
  return GamaUserTextScaler(system, preference);
}
