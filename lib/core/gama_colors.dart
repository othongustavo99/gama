import 'package:flutter/material.dart';

/// Design system Gama — carvão azulado, superfícies em camadas e âmbar.
class GamaColors {
  GamaColors._();

  // Fundos — preto quase puro com micro-variação de profundidade
  static const Color background = Color(0xFF0B0E13);
  static const Color surface = Color(0xFF10141B);
  static const Color surfaceElevated = Color(0xFF151A23);
  static const Color surfaceCard = Color(0xFF191F29);
  static const Color surfaceInput = Color(0xFF121821);
  static const Color surfaceHover = Color(0xFF222B37);

  // Laranja (accent) — mais vivo e com variantes de glow
  static const Color accent = Color(0xFFFF8A3D);
  static const Color accentSoft = Color(0x26FF8A3D);
  static const Color accentMuted = Color(0xFFD96D2B);
  static const Color accentGlow = Color(0x32FF8A3D);
  static const Color accentBright = Color(0xFFFFA66D);
  static const Color accentCool = Color(0xFF9AAEFF);

  // Texto
  static const Color textPrimary = Color(0xFFF3F5F8);
  static const Color textSecondary = Color(0xFFADB6C4);
  static const Color textMuted = Color(0xFF7D8999);
  static const Color textHint = Color(0xFF596474);

  // Bordas — mais suaves e discretas
  static const Color border = Color(0xFF2A3442);
  static const Color borderSoft = Color(0xFF202833);
  static const Color divider = Color(0xFF1C242E);

  // Feedback
  static const Color error = Color(0xFFFF5C5C);
  static const Color success = Color(0xFF34D399);

  // Bolhas
  static const Color bubbleUser = Color(0xFF33271F);
  static const Color bubbleUserSoft = Color(0xFF443025);
  static const Color bubbleAssistant = Color(0xFF121821);
}
