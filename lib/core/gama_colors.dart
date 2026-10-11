import 'package:flutter/material.dart';

/// Paleta Gamma — preto profundo, laranja vivo e branco limpo.
/// Polimento moderno estilo IA (2025/26): superfícies mais suaves,
/// hierarquia mais clara e glow discreto no accent.
class GamaColors {
  GamaColors._();

  // Fundos — preto quase puro com micro-variação de profundidade
  static const Color background = Color(0xFF08080A);
  static const Color surface = Color(0xFF0E0E11);
  static const Color surfaceElevated = Color(0xFF121216);
  static const Color surfaceCard = Color(0xFF18181C);
  static const Color surfaceInput = Color(0xFF1C1C22);
  static const Color surfaceHover = Color(0xFF222228);

  // Laranja (accent) — mais vivo e com variantes de glow
  static const Color accent = Color(0xFFFF6B00);
  static const Color accentSoft = Color(0x22FF6B00);
  static const Color accentMuted = Color(0xFFD45A00);
  static const Color accentGlow = Color(0x40FF6B00);
  static const Color accentBright = Color(0xFFFF8533);

  // Texto
  static const Color textPrimary = Color(0xFFF5F5F7);
  static const Color textSecondary = Color(0xFFA8A8B3);
  static const Color textMuted = Color(0xFF6B6B78);
  static const Color textHint = Color(0xFF484850);

  // Bordas — mais suaves e discretas
  static const Color border = Color(0xFF2A2A32);
  static const Color borderSoft = Color(0xFF222228);
  static const Color divider = Color(0xFF1A1A1F);

  // Feedback
  static const Color error = Color(0xFFFF5C5C);
  static const Color success = Color(0xFF34D399);

  // Bolhas
  static const Color bubbleUser = Color(0xFFE85D04);
  static const Color bubbleUserSoft = Color(0xFFFF6B00);
  static const Color bubbleAssistant = Color(0xFF16161A);
}
