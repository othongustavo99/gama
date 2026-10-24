import 'package:flutter/material.dart';

/// Paleta da Gama guardada no tema ativo, em vez de estado mutável global.
@immutable
class GamaPalette extends ThemeExtension<GamaPalette> {
  final Color background;
  final Color surface;
  final Color surfaceElevated;
  final Color surfaceCard;
  final Color surfaceInput;
  final Color surfaceHover;
  final Color accent;
  final Color accentSoft;
  final Color accentMuted;
  final Color accentGlow;
  final Color accentBright;
  final Color accentCool;
  final Color textPrimary;
  final Color textSecondary;
  final Color textMuted;
  final Color textHint;
  final Color border;
  final Color borderSoft;
  final Color divider;
  final Color error;
  final Color success;
  final Color bubbleUser;
  final Color bubbleUserSoft;
  final Color bubbleAssistant;

  const GamaPalette({
    required this.background,
    required this.surface,
    required this.surfaceElevated,
    required this.surfaceCard,
    required this.surfaceInput,
    required this.surfaceHover,
    required this.accent,
    required this.accentSoft,
    required this.accentMuted,
    required this.accentGlow,
    required this.accentBright,
    required this.accentCool,
    required this.textPrimary,
    required this.textSecondary,
    required this.textMuted,
    required this.textHint,
    required this.border,
    required this.borderSoft,
    required this.divider,
    required this.error,
    required this.success,
    required this.bubbleUser,
    required this.bubbleUserSoft,
    required this.bubbleAssistant,
  });

  factory GamaPalette.dark() => const GamaPalette(
    background: Color(0xFF0B0E13),
    surface: Color(0xFF10141B),
    surfaceElevated: Color(0xFF151A23),
    surfaceCard: Color(0xFF191F29),
    surfaceInput: Color(0xFF121821),
    surfaceHover: Color(0xFF222B37),
    accent: Color(0xFFFF8A3D),
    accentSoft: Color(0x26FF8A3D),
    accentMuted: Color(0xFFD96D2B),
    accentGlow: Color(0x32FF8A3D),
    accentBright: Color(0xFFFFA66D),
    accentCool: Color(0xFF9AAEFF),
    textPrimary: Color(0xFFF3F5F8),
    textSecondary: Color(0xFFADB6C4),
    textMuted: Color(0xFF7D8999),
    textHint: Color(0xFF596474),
    border: Color(0xFF2A3442),
    borderSoft: Color(0xFF202833),
    divider: Color(0xFF1C242E),
    error: Color(0xFFFF5C5C),
    success: Color(0xFF34D399),
    bubbleUser: Color(0xFF33271F),
    bubbleUserSoft: Color(0xFF443025),
    bubbleAssistant: Color(0xFF121821),
  );

  /// Identidade cromática preservada; contraste específico para superfícies claras.
  /// O balão do usuário permanece escuro para manter texto e ações legíveis.
  factory GamaPalette.light() => const GamaPalette(
    background: Color(0xFFF7F8FA),
    surface: Color(0xFFFFFFFF),
    surfaceElevated: Color(0xFFF2F4F7),
    surfaceCard: Color(0xFFFAFBFC),
    surfaceInput: Color(0xFFF3F5F8),
    surfaceHover: Color(0xFFE9EDF3),
    accent: Color(0xFFAF531C),
    accentSoft: Color(0x18AF531C),
    accentMuted: Color(0xFF934315),
    accentGlow: Color(0x1AAF531C),
    accentBright: Color(0xFFCC7334),
    accentCool: Color(0xFF425FBA),
    textPrimary: Color(0xFF1B2430),
    textSecondary: Color(0xFF4C596B),
    textMuted: Color(0xFF637083),
    textHint: Color(0xFF6D7988),
    border: Color(0xFFD5DDE6),
    borderSoft: Color(0xFFE2E7EE),
    divider: Color(0xFFE8ECF1),
    error: Color(0xFFB42332),
    success: Color(0xFF17764A),
    bubbleUser: Color(0xFF633B28),
    bubbleUserSoft: Color(0xFF754731),
    bubbleAssistant: Color(0xFFFFFFFF),
  );

  @override
  GamaPalette copyWith({
    Color? background,
    Color? surface,
    Color? surfaceElevated,
    Color? surfaceCard,
    Color? surfaceInput,
    Color? surfaceHover,
    Color? accent,
    Color? accentSoft,
    Color? accentMuted,
    Color? accentGlow,
    Color? accentBright,
    Color? accentCool,
    Color? textPrimary,
    Color? textSecondary,
    Color? textMuted,
    Color? textHint,
    Color? border,
    Color? borderSoft,
    Color? divider,
    Color? error,
    Color? success,
    Color? bubbleUser,
    Color? bubbleUserSoft,
    Color? bubbleAssistant,
  }) => GamaPalette(
    background: background ?? this.background,
    surface: surface ?? this.surface,
    surfaceElevated: surfaceElevated ?? this.surfaceElevated,
    surfaceCard: surfaceCard ?? this.surfaceCard,
    surfaceInput: surfaceInput ?? this.surfaceInput,
    surfaceHover: surfaceHover ?? this.surfaceHover,
    accent: accent ?? this.accent,
    accentSoft: accentSoft ?? this.accentSoft,
    accentMuted: accentMuted ?? this.accentMuted,
    accentGlow: accentGlow ?? this.accentGlow,
    accentBright: accentBright ?? this.accentBright,
    accentCool: accentCool ?? this.accentCool,
    textPrimary: textPrimary ?? this.textPrimary,
    textSecondary: textSecondary ?? this.textSecondary,
    textMuted: textMuted ?? this.textMuted,
    textHint: textHint ?? this.textHint,
    border: border ?? this.border,
    borderSoft: borderSoft ?? this.borderSoft,
    divider: divider ?? this.divider,
    error: error ?? this.error,
    success: success ?? this.success,
    bubbleUser: bubbleUser ?? this.bubbleUser,
    bubbleUserSoft: bubbleUserSoft ?? this.bubbleUserSoft,
    bubbleAssistant: bubbleAssistant ?? this.bubbleAssistant,
  );

  @override
  GamaPalette lerp(ThemeExtension<GamaPalette>? other, double t) {
    if (other is! GamaPalette) return this;
    return GamaPalette(
      background: Color.lerp(background, other.background, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      surfaceElevated: Color.lerp(surfaceElevated, other.surfaceElevated, t)!,
      surfaceCard: Color.lerp(surfaceCard, other.surfaceCard, t)!,
      surfaceInput: Color.lerp(surfaceInput, other.surfaceInput, t)!,
      surfaceHover: Color.lerp(surfaceHover, other.surfaceHover, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      accentSoft: Color.lerp(accentSoft, other.accentSoft, t)!,
      accentMuted: Color.lerp(accentMuted, other.accentMuted, t)!,
      accentGlow: Color.lerp(accentGlow, other.accentGlow, t)!,
      accentBright: Color.lerp(accentBright, other.accentBright, t)!,
      accentCool: Color.lerp(accentCool, other.accentCool, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      textMuted: Color.lerp(textMuted, other.textMuted, t)!,
      textHint: Color.lerp(textHint, other.textHint, t)!,
      border: Color.lerp(border, other.border, t)!,
      borderSoft: Color.lerp(borderSoft, other.borderSoft, t)!,
      divider: Color.lerp(divider, other.divider, t)!,
      error: Color.lerp(error, other.error, t)!,
      success: Color.lerp(success, other.success, t)!,
      bubbleUser: Color.lerp(bubbleUser, other.bubbleUser, t)!,
      bubbleUserSoft: Color.lerp(bubbleUserSoft, other.bubbleUserSoft, t)!,
      bubbleAssistant: Color.lerp(bubbleAssistant, other.bubbleAssistant, t)!,
    );
  }
}

extension GamaThemeContext on BuildContext {
  GamaPalette get gama =>
      Theme.of(this).extension<GamaPalette>() ?? GamaPalette.dark();
}
