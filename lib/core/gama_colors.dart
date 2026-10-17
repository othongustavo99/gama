import 'package:flutter/material.dart';

/// Paleta global da Gama. O aplicativo define a variante ao mudar ThemeMode.
/// O padrão continua escuro para preservar o visual existente.
class GamaColors {
  GamaColors._();
  static bool _lightMode = false;
  static void setLightMode(bool value) { _lightMode = value; }

  static Color get background => _lightMode ? const Color(0xFFF6F7F9) : const Color(0xFF0B0E13);
  static Color get surface => _lightMode ? const Color(0xFFFFFFFF) : const Color(0xFF10141B);
  static Color get surfaceElevated => _lightMode ? const Color(0xFFFFFFFF) : const Color(0xFF151A23);
  static Color get surfaceCard => _lightMode ? const Color(0xFFF0F2F5) : const Color(0xFF191F29);
  static Color get surfaceInput => _lightMode ? const Color(0xFFF4F5F7) : const Color(0xFF121821);
  static Color get surfaceHover => _lightMode ? const Color(0xFFE7EBF0) : const Color(0xFF222B37);

  // Laranja da marca: escurecido ligeiramente no tema claro para contraste.
  static Color get accent => _lightMode ? const Color(0xFFC45A20) : const Color(0xFFFF8A3D);
  static Color get accentSoft => _lightMode ? const Color(0x26C45A20) : const Color(0x26FF8A3D);
  static Color get accentMuted => _lightMode ? const Color(0xFFB95015) : const Color(0xFFD96D2B);
  static Color get accentGlow => _lightMode ? const Color(0x20C45A20) : const Color(0x32FF8A3D);
  static Color get accentBright => _lightMode ? const Color(0xFFB95015) : const Color(0xFFFFA66D);
  static Color get accentCool => _lightMode ? const Color(0xFF3D559D) : const Color(0xFF9AAEFF);

  static Color get textPrimary => _lightMode ? const Color(0xFF171A20) : const Color(0xFFF3F5F8);
  static Color get textSecondary => _lightMode ? const Color(0xFF46515E) : const Color(0xFFADB6C4);
  static Color get textMuted => _lightMode ? const Color(0xFF66717F) : const Color(0xFF7D8999);
  static Color get textHint => _lightMode ? const Color(0xFF7D8794) : const Color(0xFF596474);

  static Color get border => _lightMode ? const Color(0xFFD9DEE5) : const Color(0xFF2A3442);
  static Color get borderSoft => _lightMode ? const Color(0xFFE3E7ED) : const Color(0xFF202833);
  static Color get divider => _lightMode ? const Color(0xFFE6E9EF) : const Color(0xFF1C242E);

  static Color get error => _lightMode ? const Color(0xFFB42318) : const Color(0xFFFF5C5C);
  static Color get success => _lightMode ? const Color(0xFF087443) : const Color(0xFF34D399);

  static Color get bubbleUser => _lightMode ? const Color(0xFFC45A20) : const Color(0xFF33271F);
  static Color get bubbleUserSoft => _lightMode ? const Color(0xFFD96D2B) : const Color(0xFF443025);
  static Color get bubbleAssistant => _lightMode ? const Color(0xFFFFFFFF) : const Color(0xFF121821);
}
