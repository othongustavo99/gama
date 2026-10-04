import 'package:flutter/material.dart';

import '../core/gama_colors.dart';
import '../services/settings_service.dart';

/// Barra de mensagem estilo moderno (modo + anexar + campo + falar).
class ChatComposer extends StatelessWidget {
  final TextEditingController controller;
  final bool isLoading;
  final bool isListening;
  final GamaMode mode;
  final VoidCallback onAttach;
  final VoidCallback onToggleListen;
  final VoidCallback onSend;
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
          padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Chip de modo
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
              const SizedBox(height: 8),
              // Caixa principal
              Container(
                decoration: BoxDecoration(
                  color: GamaColors.surfaceCard,
                  borderRadius: BorderRadius.circular(28),
                  border: Border.all(color: GamaColors.border),
                ),
                padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
                child: isListening
                    ? _ListeningBar(
                        onCancel: onToggleListen,
                        onConfirm: () {
                          onToggleListen();
                          // texto já foi para o controller via speech
                          onSend();
                        },
                      )
                    : Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          IconButton(
                            onPressed: isLoading ? null : onAttach,
                            tooltip: 'Anexar',
                            icon: const Icon(
                              Icons.add_circle_outline_rounded,
                              color: GamaColors.textSecondary,
                            ),
                          ),
                          Expanded(
                            child: TextField(
                              controller: controller,
                              style: const TextStyle(
                                color: GamaColors.textPrimary,
                                fontSize: 15,
                              ),
                              maxLines: 5,
                              minLines: 1,
                              textCapitalization: TextCapitalization.sentences,
                              decoration: const InputDecoration(
                                hintText: 'Fazer uma pergunta',
                                hintStyle: TextStyle(
                                  color: GamaColors.textMuted,
                                  fontSize: 14,
                                ),
                                border: InputBorder.none,
                                isDense: true,
                                contentPadding: EdgeInsets.symmetric(
                                  horizontal: 4,
                                  vertical: 12,
                                ),
                              ),
                              onSubmitted: (_) {
                                if (!isLoading) onSend();
                              },
                            ),
                          ),
                          // Falar
                          Padding(
                            padding: const EdgeInsets.only(bottom: 4, right: 2),
                            child: TextButton.icon(
                              onPressed: isLoading ? null : onToggleListen,
                              style: TextButton.styleFrom(
                                backgroundColor: GamaColors.surfaceElevated,
                                foregroundColor: GamaColors.textPrimary,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 10,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(22),
                                  side: const BorderSide(
                                    color: GamaColors.border,
                                  ),
                                ),
                                elevation: 0,
                              ),
                              icon: const Icon(
                                Icons.graphic_eq_rounded,
                                size: 18,
                              ),
                              label: const Text(
                                'Falar',
                                style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                          ),
                          // Enviar
                          Padding(
                            padding: const EdgeInsets.only(bottom: 4, right: 4),
                            child: Material(
                              color: GamaColors.accent,
                              shape: const CircleBorder(),
                              child: InkWell(
                                customBorder: const CircleBorder(),
                                onTap: isLoading ? null : onSend,
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
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: selected
                  ? GamaColors.accent.withOpacity(0.55)
                  : GamaColors.border,
            ),
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
                      ? GamaColors.accent
                      : GamaColors.textSecondary,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ListeningBar extends StatelessWidget {
  final VoidCallback onCancel;
  final VoidCallback onConfirm;

  const _ListeningBar({required this.onCancel, required this.onConfirm});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      child: Row(
        children: [
          IconButton(
            onPressed: onCancel,
            icon: const Icon(Icons.close_rounded, color: GamaColors.textMuted),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Ouvindo…',
                  style: TextStyle(
                    color: GamaColors.textSecondary,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 6),
                // waveform simples
                SizedBox(
                  height: 28,
                  child: Row(
                    children: List.generate(24, (i) {
                      final h = 6.0 + (i % 5) * 4.0;
                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 1.5),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          width: 3,
                          height: h,
                          decoration: BoxDecoration(
                            color: GamaColors.accent.withOpacity(0.85),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      );
                    }),
                  ),
                ),
              ],
            ),
          ),
          Material(
            color: GamaColors.accent,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onConfirm,
              child: const SizedBox(
                width: 40,
                height: 40,
                child: Icon(Icons.check_rounded, color: Colors.white, size: 22),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
