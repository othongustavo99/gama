import 'package:flutter/material.dart';

/// Paleta oficial Gamma — preto, laranja e branco (discreto).
class GamaColors {
  GamaColors._();

  // Fundos
  static const Color background = Color(0xFF0A0A0A);
  static const Color surface = Color(0xFF111111);
  static const Color surfaceElevated = Color(0xFF171717);
  static const Color surfaceCard = Color(0xFF1C1C1C);
  static const Color surfaceInput = Color(0xFF1A1A1A);

  // Laranja (accent — usar com parcimônia)
  static const Color accent = Color(0xFFFF6B00);
  static const Color accentSoft = Color(0x33FF6B00); // ~20% opacity
  static const Color accentMuted = Color(0xFFCC5500);

  // Texto
  static const Color textPrimary = Color(0xFFFFFFFF);
  static const Color textSecondary = Color(0xFFB3B3B3);
  static const Color textMuted = Color(0xFF6B6B6B);
  static const Color textHint = Color(0xFF4A4A4A);

  // Bordas / divisores
  static const Color border = Color(0xFF2A2A2A);
  static const Color divider = Color(0xFF222222);

  // Feedback
  static const Color error = Color(0xFFFF5252);
  static const Color success = Color(0xFF4CAF50);

  // Bolhas de chat
  static const Color bubbleUser = accent;
  static const Color bubbleAssistant = Color(0xFF1C1C1C);
}
