import 'package:flutter/material.dart';

import '../core/gama_colors.dart';
import '../services/settings_service.dart';

/// Barra: modo · + · mic (STT com texto ao vivo) · campo · ondas (TTS) · enviar
/// Polimento visual moderno — input glass, chips mais suaves e botão de envio com glow.
class ChatComposer extends StatelessWidget {
  final TextEditingController controller;
  final bool isLoading;
  final bool isListening;
  final GamaMode mode;
  final VoidCallback onAttach;
  final VoidCallback onToggleListen;
  final VoidCallback onSend;
  final VoidCallback onSpeakSend;
  final ValueChanged<GamaMode> onModeChanged;

  const ChatComposer({
    super.key,
    required this.controller,
    required this.isLoading,
    required this.isListening,
    required this.mode,
    required this.onAttach,
    required this.onToggleListen,
    required this.onSend,
    required this.onSpeakSend,
    required this.onModeChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: GamaColors.surface,
      elevation: 0,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      _ModeChip(
                        label: 'Programar',
                        icon: Icons.code_rounded,
                        selected: mode == GamaMode.programar,
                        onTap: () => onModeChanged(GamaMode.programar),
                      ),
                      const SizedBox(width: 8),
                      _ModeChip(
                        label: 'Conversar',
                        icon: Icons.chat_bubble_outline_rounded,
                        selected: mode == GamaMode.conversar,
                        onTap: () => onModeChanged(GamaMode.conversar),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 10),
              AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                decoration: BoxDecoration(
                  color: GamaColors.surfaceCard,
                  borderRadius: BorderRadius.circular(26),
                  border: Border.all(
                    color: isListening
                        ? GamaColors.accent.withOpacity(0.55)
                        : GamaColors.border,
                    width: isListening ? 1.2 : 1,
                  ),
                  boxShadow: isListening
                      ? [
                          BoxShadow(
                            color: GamaColors.accentGlow,
                            blurRadius: 16,
                            spreadRadius: 0,
                            offset: const Offset(0, 2),
                          ),
                        ]
                      : [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.35),
                            blurRadius: 12,
                            offset: const Offset(0, 4),
                          ),
                        ],
                ),
                padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    IconButton(
                      onPressed: isLoading ? null : onAttach,
                      tooltip: 'Anexar',
                      style: IconButton.styleFrom(
                        foregroundColor: GamaColors.textSecondary,
                        disabledForegroundColor: GamaColors.textHint,
                      ),
                      icon: const Icon(
                        Icons.add_circle_outline_rounded,
                        size: 24,
                      ),
                    ),
                    IconButton(
                      onPressed: isLoading ? null : onToggleListen,
                      tooltip: isListening
                          ? 'Parar gravação'
                          : 'Gravar voz → texto',
                      style: IconButton.styleFrom(
                        foregroundColor: isListening
                            ? GamaColors.accent
                            : GamaColors.textSecondary,
                        disabledForegroundColor: GamaColors.textHint,
                      ),
                      icon: Icon(
                        isListening ? Icons.mic : Icons.mic_none_rounded,
                        size: 24,
                      ),
                    ),
                    Expanded(
                      child: TextField(
                        controller: controller,
                        style: const TextStyle(
                          color: GamaColors.textPrimary,
                          fontSize: 15.5,
                          height: 1.35,
                          letterSpacing: 0.1,
                        ),
                        maxLines: 5,
                        minLines: 1,
                        textCapitalization: TextCapitalization.sentences,
                        decoration: InputDecoration(
                          hintText: isListening
                              ? 'Ouvindo… o texto aparece aqui'
                              : 'Fazer uma pergunta',
                          hintStyle: const TextStyle(
                            color: GamaColors.textMuted,
                            fontSize: 14.5,
                          ),
                          border: InputBorder.none,
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 12,
                          ),
                        ),
                        onSubmitted: (_) {
                          if (!isLoading) onSend();
                        },
                      ),
                    ),
                    IconButton(
                      onPressed: isLoading ? null : onSpeakSend,
                      tooltip: 'Enviar e ouvir a resposta',
                      style: IconButton.styleFrom(
                        foregroundColor: GamaColors.textSecondary,
                        disabledForegroundColor: GamaColors.textHint,
                      ),
                      icon: const Icon(
                        Icons.graphic_eq_rounded,
                        size: 22,
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 3, right: 3),
                      child: Material(
                        color: isLoading
                            ? GamaColors.accent.withOpacity(0.45)
                            : GamaColors.accent,
                        shape: const CircleBorder(),
                        elevation: isLoading ? 0 : 2,
                        shadowColor: GamaColors.accentGlow,
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: isLoading ? null : onSend,
                          child: const SizedBox(
                            width: 42,
                            height: 42,
                            child: Icon(
                              Icons.arrow_upward_rounded,
                              color: Colors.white,
                              size: 21,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ModeChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  const _ModeChip({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? GamaColors.accentSoft : GamaColors.surfaceCard,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: selected
                  ? GamaColors.accent.withOpacity(0.55)
                  : GamaColors.border,
              width: selected ? 1.1 : 1,
            ),
            boxShadow: selected
                ? [
                    BoxShadow(
                      color: GamaColors.accentGlow.withOpacity(0.35),
                      blurRadius: 8,
                      offset: const Offset(0, 1),
                    ),
                  ]
                : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 15,
                color: selected ? GamaColors.accent : GamaColors.textMuted,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  color: selected
                      ? GamaColors.accentBright
                      : GamaColors.textSecondary,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.1,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
