import 'package:flutter/material.dart';

import '../core/gama_colors.dart';
import '../services/settings_service.dart';

/// Barra de envio no estilo da home:
/// - Caixa arredondada única
/// - Campo de texto SEM fundo/caixa própria (só o placeholder)
/// - Linha de ferramentas: modo · + · mic · ondas · enviar
class ChatComposer extends StatelessWidget {
  final TextEditingController controller;
  final bool isLoading;
  final bool isListening;
  final GamaMode mode;
  final VoidCallback onAttach;
  final VoidCallback onToggleListen;
  final VoidCallback onSend;
  final VoidCallback onSpeakSend;
  final VoidCallback? onStop;
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
    this.onStop,
    required this.onModeChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: GamaColors.surface,
        border: Border(top: BorderSide(color: GamaColors.divider)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.18),
            blurRadius: 18,
            offset: const Offset(0, -5),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            decoration: BoxDecoration(
              color: GamaColors.surfaceCard,
              borderRadius: BorderRadius.circular(22),
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
                        offset: const Offset(0, 2),
                      ),
                    ]
                  : [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.18),
                        blurRadius: 16,
                        offset: const Offset(0, 5),
                      ),
                    ],
            ),
            padding: const EdgeInsets.fromLTRB(14, 12, 8, 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Campo de texto — SEM caixa de fundo por trás do placeholder
                TextField(
                  controller: controller,
                  style: TextStyle(
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
                        : 'Escreva sua mensagem...',
                    hintStyle: TextStyle(
                      color: GamaColors.textMuted,
                      fontSize: 14.5,
                    ),
                    // Remove qualquer fundo/caixa do tema global
                    filled: false,
                    fillColor: Colors.transparent,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    disabledBorder: InputBorder.none,
                    errorBorder: InputBorder.none,
                    focusedErrorBorder: InputBorder.none,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 2,
                      vertical: 6,
                    ),
                  ),
                  onSubmitted: (_) {
                    if (!isLoading) onSend();
                  },
                ),
                const SizedBox(height: 6),
                // Linha de ferramentas (igual à captura)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    // Chip de modo (Programar / Conversar)
                    _ModeChip(
                      label: mode == GamaMode.programar
                          ? 'Programar'
                          : 'Conversar',
                      icon: mode == GamaMode.programar
                          ? Icons.code_rounded
                          : Icons.chat_bubble_outline_rounded,
                      selected: true,
                      onTap: () {
                        final next = mode == GamaMode.programar
                            ? GamaMode.conversar
                            : GamaMode.programar;
                        onModeChanged(next);
                      },
                    ),
                    const Spacer(),
                    IconButton(
                      onPressed: isLoading ? null : onAttach,
                      tooltip: 'Anexar',
                      style: IconButton.styleFrom(
                        foregroundColor: GamaColors.textSecondary,
                        disabledForegroundColor: GamaColors.textHint,
                        visualDensity: VisualDensity.compact,
                      ),
                      icon: const Icon(
                        Icons.add_circle_outline_rounded,
                        size: 22,
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
                        visualDensity: VisualDensity.compact,
                      ),
                      icon: Icon(
                        isListening ? Icons.mic : Icons.mic_none_rounded,
                        size: 22,
                      ),
                    ),
                    IconButton(
                      onPressed: isLoading ? null : onSpeakSend,
                      tooltip: 'Enviar e ouvir a resposta',
                      style: IconButton.styleFrom(
                        foregroundColor: GamaColors.textSecondary,
                        disabledForegroundColor: GamaColors.textHint,
                        visualDensity: VisualDensity.compact,
                      ),
                      icon: const Icon(Icons.graphic_eq_rounded, size: 20),
                    ),
                    const SizedBox(width: 4),
                    Material(
                      color: isLoading
                          ? GamaColors.accent.withOpacity(0.45)
                          : GamaColors.accent,
                      borderRadius: BorderRadius.circular(14),
                      elevation: isLoading ? 0 : 2,
                      shadowColor: GamaColors.accentGlow,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(14),
                        onTap: isLoading ? onStop : onSend,
                        child: const SizedBox(
                          width: 40,
                          height: 40,
                          child: Icon(
                            Icons.arrow_upward_rounded,
                            color: Colors.white,
                            size: 20,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
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
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: selected
                  ? GamaColors.accent.withOpacity(0.55)
                  : GamaColors.border,
              width: selected ? 1.1 : 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 14,
                color: selected ? GamaColors.accent : GamaColors.textMuted,
              ),
              const SizedBox(width: 5),
              Text(
                label,
                style: TextStyle(
                  color: selected
                      ? GamaColors.accentBright
                      : GamaColors.textSecondary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.1,
                ),
              ),
              const SizedBox(width: 2),
              Icon(
                Icons.keyboard_arrow_down_rounded,
                size: 16,
                color: selected ? GamaColors.accent : GamaColors.textMuted,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
