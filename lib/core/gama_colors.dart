import 'package:flutter/material.dart';

/// Paleta Gamma — preto, laranja e branco (discreto, moderno).
/// Mesmo jogo de cores; hierarquia e superfícies um pouco mais refinadas.
class GamaColors {
  GamaColors._();

  // Fundos
  static const Color background = Color(0xFF0A0A0B);
  static const Color surface = Color(0xFF111113);
  static const Color surfaceElevated = Color(0xFF151518);
  static const Color surfaceCard = Color(0xFF1B1B1F);
  static const Color surfaceInput = Color(0xFF1F1F24);

  // Laranja (accent)
  static const Color accent = Color(0xFFFF6B00);
  static const Color accentSoft = Color(0x2AFF6B00);
  static const Color accentMuted = Color(0xFFD45A00);
  static const Color accentGlow = Color(0x45FF6B00);

  // Texto
  static const Color textPrimary = Color(0xFFF7F7F8);
  static const Color textSecondary = Color(0xFFB0B0B8);
  static const Color textMuted = Color(0xFF72727C);
  static const Color textHint = Color(0xFF4E4E56);

  // Bordas
  static const Color border = Color(0xFF2C2C33);
  static const Color borderSoft = Color(0xFF24242A);
  static const Color divider = Color(0xFF1C1C20);

  // Feedback
  static const Color error = Color(0xFFFF5C5C);
  static const Color success = Color(0xFF3DDB8A);

  // Bolhas
  static const Color bubbleUser = Color(0xFFE85D04);
  static const Color bubbleUserSoft = Color(0xFFFF6B00);
  static const Color bubbleAssistant = Color(0xFF1B1B1F);
}
