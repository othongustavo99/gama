import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
  final VoidCallback? onPasteImage;
  final FocusNode? focusNode;

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
    this.onPasteImage,
    this.focusNode,
  });

  bool get _usesDesktopEnterShortcut =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.linux);

  void _submitIfPossible() {
    if (!isLoading && controller.text.trim().isNotEmpty) {
      onSend();
    }
  }

  @override
  Widget build(BuildContext context) {
    final shortcuts = <ShortcutActivator, Intent>{
      if (_usesDesktopEnterShortcut)
        const SingleActivator(LogicalKeyboardKey.enter):
            const _SendMessageIntent(),
    };

    return Container(
      color: context.gama.surface,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            decoration: BoxDecoration(
              color: context.gama.surfaceCard,
              borderRadius: BorderRadius.circular(22),
              border: Border.all(
                color: isListening
                    ? context.gama.accent.withValues(alpha: 0.55)
                    : context.gama.border,
                width: isListening ? 1.2 : 1,
              ),
              boxShadow: isListening
                  ? [
                      BoxShadow(
                        color: context.gama.accentGlow,
                        blurRadius: 16,
                        offset: const Offset(0, 2),
                      ),
                    ]
                  : const [],
            ),
            padding: const EdgeInsets.fromLTRB(14, 12, 8, 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Campo de texto — SEM caixa de fundo por trás do placeholder.
                // No desktop, Enter envia e Shift+Enter continua inserindo
                // uma quebra de linha (o atalho não é registrado com Shift).
                CallbackShortcuts(
                  bindings: <ShortcutActivator, VoidCallback>{
                    if (_usesDesktopEnterShortcut && onPasteImage != null)
                      const SingleActivator(
                        LogicalKeyboardKey.keyV,
                        control: true,
                      ): onPasteImage!,
                  },
                  child: Shortcuts(
                    shortcuts: shortcuts,
                    child: Actions(
                      actions: <Type, Action<Intent>>{
                        _SendMessageIntent: CallbackAction<_SendMessageIntent>(
                          onInvoke: (_) {
                            _submitIfPossible();
                            return null;
                          },
                        ),
                      },
                      child: TextField(
                        controller: controller,
                        focusNode: focusNode,
                        style: TextStyle(
                          color: context.gama.textPrimary,
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
                            color: context.gama.textMuted,
                            fontSize: 14.5,
                          ),
                          // Remove qualquer fundo/caixa do tema global.
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
                        onSubmitted: (_) => _submitIfPossible(),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                // Linha de ferramentas (igual à captura).
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    // Chip de modo (Programar / Conversar).
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
                        foregroundColor: context.gama.textSecondary,
                        disabledForegroundColor: context.gama.textHint,
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
                            ? context.gama.accent
                            : context.gama.textSecondary,
                        disabledForegroundColor: context.gama.textHint,
                        visualDensity: VisualDensity.compact,
                      ),
                      icon: Icon(
                        isListening ? Icons.mic : Icons.mic_none_rounded,
                        size: 22,
                      ),
                    ),
                    IconButton(
                      onPressed: isLoading ? null : onSpeakSend,
                      tooltip: 'Enviar e ouvir resposta',
                      style: IconButton.styleFrom(
                        foregroundColor: context.gama.accent,
                        disabledForegroundColor: context.gama.textHint,
                        visualDensity: VisualDensity.compact,
                      ),
                      icon: const Icon(Icons.graphic_eq_rounded, size: 22),
                    ),
                    const SizedBox(width: 4),
                    Material(
                      color: isLoading
                          ? context.gama.accent.withValues(alpha: 0.45)
                          : context.gama.accent,
                      borderRadius: BorderRadius.circular(14),
                      elevation: isLoading ? 0 : 2,
                      shadowColor: context.gama.accentGlow,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(14),
                        onTap: isLoading ? onStop : onSend,
                        child: SizedBox(
                          width: 40,
                          height: 40,
                          child: Icon(
                            isLoading
                                ? Icons.stop_rounded
                                : Icons.arrow_upward_rounded,
                            color: Colors.white,
                            size: isLoading ? 22 : 20,
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

class _SendMessageIntent extends Intent {
  const _SendMessageIntent();
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
      color: selected ? context.gama.accentSoft : context.gama.surfaceCard,
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
                  ? context.gama.accent.withValues(alpha: 0.55)
                  : context.gama.border,
              width: selected ? 1.1 : 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 14,
                color: selected ? context.gama.accent : context.gama.textMuted,
              ),
              const SizedBox(width: 5),
              Text(
                label,
                style: TextStyle(
                  color: selected
                      ? context.gama.accentBright
                      : context.gama.textSecondary,
                  fontSize: 12,
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
