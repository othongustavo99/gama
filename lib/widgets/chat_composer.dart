import 'package:flutter/material.dart';

import '../core/gama_colors.dart';
import '../services/settings_service.dart';

/// Composer responsivo: o campo de texto ocupa a linha superior inteira e os
/// controles ficam numa barra inferior. Assim, os ícones nunca comprimem o texto.
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
    final borderColor = isListening ? GamaColors.accent : GamaColors.border;

    return Container(
      decoration: BoxDecoration(
        color: GamaColors.surface,
        border: Border(top: BorderSide(color: GamaColors.divider)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.18),
            blurRadius: 18,
            offset: const Offset(0, -5),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 9, 12, 10),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            decoration: BoxDecoration(
              color: Colors.transparent,
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
                        color: GamaColors.accentGlow.withValues(alpha: 0.25),
                        blurRadius: 16,
                        offset: const Offset(0, 2),
                      ),
                    ]
                  : [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.12),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Texto numa linha própria, sem os botões a disputar largura.
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 7, 14, 0),
                  child: TextField(
                    controller: controller,
                    minLines: 1,
                    maxLines: 5,
                    textCapitalization: TextCapitalization.sentences,
                    textInputAction: TextInputAction.newline,
                    style: TextStyle(
                      color: GamaColors.textPrimary,
                      fontSize: 16,
                      height: 1.35,
                      letterSpacing: 0.05,
                    ),
                    decoration: InputDecoration(
                      hintText: isListening
                          ? 'Ouvindo… pode continuar falando'
                          : 'Escreva sua mensagem…',
                      hintStyle: TextStyle(
                        color: GamaColors.textMuted,
                        fontSize: 15,
                      ),
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(vertical: 9),
                    ),
                    onSubmitted: (_) {
                      if (!isLoading && controller.text.trim().isNotEmpty) {
                        onSend();
                      }
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(7, 2, 7, 6),
                  child: Row(
                    children: [
                      // Seletor compacto; não mantém uma linha de chips acima do campo.
                      PopupMenuButton<GamaMode>(
                        tooltip: 'Modo de resposta',
                        padding: EdgeInsets.zero,
                        onSelected: onModeChanged,
                        itemBuilder: (context) => const [
                          PopupMenuItem(
                            value: GamaMode.programar,
                            child: Row(
                              children: [
                                Icon(Icons.code_rounded, size: 18),
                                SizedBox(width: 10),
                                Text('Programar'),
                              ],
                            ),
                          ),
                          PopupMenuItem(
                            value: GamaMode.conversar,
                            child: Row(
                              children: [
                                Icon(
                                  Icons.chat_bubble_outline_rounded,
                                  size: 18,
                                ),
                                SizedBox(width: 10),
                                Text('Conversar'),
                              ],
                            ),
                          ),
                        ],
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(minHeight: 40),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 5),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  mode == GamaMode.programar
                                      ? Icons.code_rounded
                                      : Icons.chat_bubble_outline_rounded,
                                  size: 18,
                                  color: GamaColors.accent,
                                ),
                                const SizedBox(width: 5),
                                Text(
                                  mode == GamaMode.programar
                                      ? 'Programar'
                                      : 'Conversar',
                                  style: TextStyle(
                                    color: GamaColors.textSecondary,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                Icon(
                                  Icons.arrow_drop_down_rounded,
                                  size: 18,
                                  color: GamaColors.textMuted,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 1),
                      _ComposerIconButton(
                        tooltip: 'Anexar arquivo ou imagem',
                        onPressed: isLoading ? null : onAttach,
                        icon: Icons.add_circle_outline_rounded,
                      ),
                      _ComposerIconButton(
                        tooltip: isListening
                            ? 'Parar microfone'
                            : 'Ditado por voz',
                        onPressed: isLoading ? null : onToggleListen,
                        icon: isListening
                            ? Icons.mic_rounded
                            : Icons.mic_none_rounded,
                        color: isListening
                            ? GamaColors.accent
                            : GamaColors.textSecondary,
                      ),
                      const Spacer(),
                      _ComposerIconButton(
                        tooltip: 'Enviar e ouvir a resposta',
                        onPressed: isLoading ? null : onSpeakSend,
                        icon: Icons.graphic_eq_rounded,
                      ),
                      const SizedBox(width: 3),
                      Semantics(
                        button: true,
                        label: isLoading ? 'Parar geração' : 'Enviar mensagem',
                        child: Material(
                          color: isLoading
                              ? GamaColors.surfaceHover
                              : GamaColors.accent,
                          borderRadius: BorderRadius.circular(15),
                          elevation: isLoading ? 0 : 2,
                          shadowColor: GamaColors.accentGlow,
                          child: InkWell(
                            borderRadius: BorderRadius.circular(15),
                            onTap: isLoading ? onStop : onSend,
                            child: SizedBox(
                              width: 46,
                              height: 44,
                              child: Icon(
                                isLoading
                                    ? Icons.stop_rounded
                                    : Icons.arrow_upward_rounded,
                                color: isLoading
                                    ? GamaColors.accent
                                    : Colors.white,
                                size: 22,
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
      ),
    );
  }
}

class _ComposerIconButton extends StatelessWidget {
  final String tooltip;
  final VoidCallback? onPressed;
  final IconData icon;
  final Color? color;

  const _ComposerIconButton({
    required this.tooltip,
    required this.onPressed,
    required this.icon,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints.tightFor(width: 40, height: 40),
      padding: EdgeInsets.zero,
      style: IconButton.styleFrom(
        foregroundColor: color ?? GamaColors.textSecondary,
        disabledForegroundColor: GamaColors.textHint,
      ),
      icon: Icon(icon, size: 22),
    );
  }
}
