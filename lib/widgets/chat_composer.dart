import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/gama_colors.dart';
import '../core/gama_page_route.dart';
import '../screens/oficina_screen.dart';
import '../models/oficina_kind.dart';
import '../services/settings_service.dart';

/// Barra de envio no estilo da home:
/// - Caixa arredondada única
/// - Campo de texto SEM fundo/caixa própria (só o placeholder)
/// - Linha de ferramentas: Oficina · + · mic · ondas · enviar
class ChatComposer extends StatelessWidget {
  final TextEditingController controller;
  final bool isLoading;
  final bool isListening;
  final bool hasAttachments;
  final bool attachmentsReady;
  final GamaMode mode;
  final VoidCallback onAttach;
  final VoidCallback onToggleListen;
  final VoidCallback? onOpenVoice;
  final VoidCallback onSend;
  final VoidCallback onSpeakSend;
  final VoidCallback? onStop;
  final ValueChanged<GamaMode> onModeChanged;
  final VoidCallback? onPasteImage;
  final FocusNode? focusNode;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSlashCommandSelected;
  final bool showSlashMenu;
  final OficinaKind? oficinaKind;
  final String? placeholder;
  final VoidCallback? onExitOficina;
  final String imageAspectRatio;
  final String imageStyle;
  final int videoDuration;
  final String videoResolution;
  final String videoAspectRatio;
  final bool videoGenerateAudio;
  final ValueChanged<int>? onVideoDurationChanged;
  final ValueChanged<String>? onVideoResolutionChanged;
  final ValueChanged<String>? onVideoAspectRatioChanged;
  final ValueChanged<bool>? onVideoGenerateAudioChanged;
  final ValueChanged<String>? onImageAspectRatioChanged;
  final ValueChanged<String>? onImageStyleChanged;
  final List<Widget> oficinaShortcuts;

  const ChatComposer({
    super.key,
    required this.controller,
    required this.isLoading,
    required this.isListening,
    this.hasAttachments = false,
    this.attachmentsReady = true,
    required this.mode,
    required this.onAttach,
    required this.onToggleListen,
    this.onOpenVoice,
    required this.onSend,
    required this.onSpeakSend,
    this.onStop,
    required this.onModeChanged,
    this.onPasteImage,
    this.focusNode,
    this.onChanged,
    this.onSlashCommandSelected,
    this.showSlashMenu = false,
    this.oficinaKind,
    this.placeholder,
    this.onExitOficina,
    this.imageAspectRatio = '1:1',
    this.imageStyle = 'Automático',
    this.videoDuration = 5,
    this.videoResolution = '480p',
    this.videoAspectRatio = '16:9',
    this.videoGenerateAudio = true,
    this.onVideoDurationChanged,
    this.onVideoResolutionChanged,
    this.onVideoAspectRatioChanged,
    this.onVideoGenerateAudioChanged,
    this.onImageAspectRatioChanged,
    this.onImageStyleChanged,
    this.oficinaShortcuts = const [],
  });

  bool get _usesDesktopEnterShortcut =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.linux);

  void _submitIfPossible() {
    if (!isLoading && attachmentsReady &&
        (controller.text.trim().isNotEmpty || hasAttachments)) {
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

    final slashCommands =
        <(String, String)>[
              ('/memoria', 'Consultar fatos salvos'),
              ('/memoria limpar', 'Apagar fatos salvos'),
              ('/memoria ', 'Salvar um fato na memória'),
              ('/limpar', 'Limpar esta conversa'),
              if (oficinaKind == null) ...[
                ('/modo programar', 'Mudar para Trabalhar'),
                ('/modo conversar', 'Mudar para Conversar'),
              ],
            ]
            .where(
              (entry) =>
                  entry.$1.startsWith(controller.text.trimRight()) ||
                  controller.text == '/',
            )
            .toList();
    final reducedMotion = MediaQuery.of(context).disableAnimations;
    final palette = context.gama;
    return AnimatedBuilder(
      animation: focusNode ?? controller,
      builder: (context, child) {
        final focused = focusNode?.hasFocus ?? false;
        return ColoredBox(
          color: palette.background,
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
              child: Container(
                padding: const EdgeInsets.all(1),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(24),
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      palette.accent.withValues(alpha: focused ? 0.75 : 0.35),
                      palette.border,
                      palette.accentCool.withValues(
                        alpha: focused ? 0.44 : 0.28,
                      ),
                    ],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: palette.accentGlow.withValues(
                        alpha: focused ? 0.50 : 0.22,
                      ),
                      blurRadius: focused ? 24 : 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(23),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 13, sigmaY: 13),
                    child: AnimatedContainer(
                      duration: reducedMotion
                          ? Duration.zero
                          : const Duration(milliseconds: 220),
                      curve: Curves.easeOutCubic,
                      decoration: BoxDecoration(
                        color: palette.surfaceCard.withValues(alpha: 0.91),
                        borderRadius: BorderRadius.circular(22),
                        border: Border.all(
                          color: isListening || focused
                              ? palette.accent.withValues(alpha: 0.54)
                              : Colors.transparent,
                          width: 1,
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
                          if (oficinaShortcuts.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Wrap(
                                spacing: 7,
                                runSpacing: 5,
                                children: oficinaShortcuts,
                              ),
                            ),
                          if (oficinaKind == OficinaKind.imagem)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Wrap(
                                spacing: 7,
                                runSpacing: 6,
                                children: [
                                  for (final ratio in const [
                                    '1:1',
                                    '16:9',
                                    '9:16',
                                  ])
                                    ChoiceChip(
                                      label: Text(ratio),
                                      selected: imageAspectRatio == ratio,
                                      onSelected: (_) =>
                                          onImageAspectRatioChanged?.call(
                                            ratio,
                                          ),
                                      visualDensity: VisualDensity.compact,
                                      labelStyle: TextStyle(
                                        color: context.gama.textSecondary,
                                        fontSize: 11,
                                      ),
                                    ),
                                  for (final style in const [
                                    'Automático',
                                    'Foto',
                                    'Ilustração',
                                    '3D',
                                  ])
                                    ChoiceChip(
                                      label: Text(style),
                                      selected: imageStyle == style,
                                      onSelected: (_) =>
                                          onImageStyleChanged?.call(style),
                                      visualDensity: VisualDensity.compact,
                                      labelStyle: TextStyle(
                                        color: context.gama.textSecondary,
                                        fontSize: 11,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          if (oficinaKind == OficinaKind.video)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Wrap(
                                spacing: 7,
                                runSpacing: 6,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  for (final seconds in const [5, 10, 15])
                                    ChoiceChip(
                                      label: Text('${seconds}s'),
                                      selected: videoDuration == seconds,
                                      onSelected: (_) => onVideoDurationChanged?.call(seconds),
                                      visualDensity: VisualDensity.compact,
                                    ),
                                  for (final res in const ['480p', '720p'])
                                    ChoiceChip(
                                      label: Text(res),
                                      selected: videoResolution == res,
                                      onSelected: (_) => onVideoResolutionChanged?.call(res),
                                      visualDensity: VisualDensity.compact,
                                    ),
                                  for (final ratio in const ['16:9', '9:16', '1:1'])
                                    ChoiceChip(
                                      label: Text(ratio),
                                      selected: videoAspectRatio == ratio,
                                      onSelected: (_) => onVideoAspectRatioChanged?.call(ratio),
                                      visualDensity: VisualDensity.compact,
                                    ),
                                  FilterChip(
                                    label: const Text('Áudio'),
                                    selected: videoGenerateAudio,
                                    onSelected: onVideoGenerateAudioChanged,
                                    visualDensity: VisualDensity.compact,
                                  ),
                                ],
                              ),
                            ),
                          if (showSlashMenu && slashCommands.isNotEmpty)
                            Container(
                              margin: const EdgeInsets.only(bottom: 8),
                              constraints: const BoxConstraints(maxHeight: 190),
                              decoration: BoxDecoration(
                                color: context.gama.surfaceCard,
                                border: Border.all(color: context.gama.border),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: ListView(
                                shrinkWrap: true,
                                children: [
                                  for (final command in slashCommands)
                                    ListTile(
                                      dense: true,
                                      title: Text(
                                        command.$1,
                                        style: TextStyle(
                                          color: context.gama.textPrimary,
                                        ),
                                      ),
                                      subtitle: Text(
                                        command.$2,
                                        style: TextStyle(
                                          color: context.gama.textMuted,
                                        ),
                                      ),
                                      onTap: () => onSlashCommandSelected?.call(
                                        command.$1,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          // Campo de texto — SEM caixa de fundo por trás do placeholder.
                          // No desktop, Enter envia e Shift+Enter continua inserindo
                          // uma quebra de linha (o atalho não é registrado com Shift).
                          CallbackShortcuts(
                            bindings: <ShortcutActivator, VoidCallback>{
                              if (_usesDesktopEnterShortcut &&
                                  onPasteImage != null)
                                const SingleActivator(
                                  LogicalKeyboardKey.keyV,
                                  control: true,
                                ): onPasteImage!,
                            },
                            child: Shortcuts(
                              shortcuts: shortcuts,
                              child: Actions(
                                actions: <Type, Action<Intent>>{
                                  _SendMessageIntent:
                                      CallbackAction<_SendMessageIntent>(
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
                                  textCapitalization:
                                      TextCapitalization.sentences,
                                  decoration: InputDecoration(
                                    hintText: isListening
                                        ? 'Ouvindo… o texto aparece aqui'
                                        : placeholder ??
                                              'Escreva sua mensagem...',
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
                                  onChanged: onChanged,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 6),
                          // Linha de ferramentas (igual à captura).
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              // Botão único "Oficina" (substitui o toggle Programar/Conversar).
                              // Visual: fundo escuro + traços brancos. Abre a tela Oficina.
                              _ModeChip(
                                label: oficinaKind == null
                                    ? 'Oficina'
                                    : '${oficinaKind!.label}  ×',
                                icon:
                                    oficinaKind?.icon ?? Icons.handyman_rounded,
                                selected: true,
                                onTap: oficinaKind == null
                                    ? () {
                                        Navigator.of(context).push(
                                          GamaPageRoute<void>(
                                            builder: (_) =>
                                                const OficinaScreen(),
                                          ),
                                        );
                                      }
                                    : (onExitOficina ?? () {}),
                              ),
                              const Spacer(),
                              IconButton(
                                onPressed: isLoading
                                    ? null
                                    : () {
                                        HapticFeedback.selectionClick();
                                        onAttach();
                                      },
                                tooltip: 'Anexar',
                                style: IconButton.styleFrom(
                                  foregroundColor: context.gama.textSecondary,
                                  disabledForegroundColor:
                                      context.gama.textHint,
                                  visualDensity: VisualDensity.compact,
                                ),
                                icon: const Icon(
                                  Icons.add_circle_outline_rounded,
                                  size: 22,
                                ),
                              ),
                              GestureDetector(
                                onLongPress: onOpenVoice == null || isLoading
                                    ? null
                                    : () {
                                        HapticFeedback.mediumImpact();
                                        onOpenVoice!();
                                      },
                                child: IconButton(
                                  onPressed: isLoading
                                      ? null
                                      : () {
                                          HapticFeedback.selectionClick();
                                          onToggleListen();
                                        },
                                  tooltip: onOpenVoice == null
                                      ? (isListening
                                            ? 'Parar gravação'
                                            : 'Gravar voz → texto')
                                      : 'Ditado: toque. Conversa por voz: segure.',
                                  style: IconButton.styleFrom(
                                    foregroundColor: isListening
                                        ? context.gama.accent
                                        : context.gama.textSecondary,
                                    disabledForegroundColor:
                                        context.gama.textHint,
                                    visualDensity: VisualDensity.compact,
                                  ),
                                  icon: Icon(
                                    isListening
                                        ? Icons.mic
                                        : Icons.mic_none_rounded,
                                    size: 22,
                                  ),
                                ),
                              ),
                              if (oficinaKind == null)
                                IconButton(
                                  onPressed: isLoading
                                      ? null
                                      : () {
                                          HapticFeedback.lightImpact();
                                          onSpeakSend();
                                        },
                                  tooltip: 'Enviar e ouvir resposta',
                                  style: IconButton.styleFrom(
                                    foregroundColor: context.gama.accent,
                                    disabledForegroundColor:
                                        context.gama.textHint,
                                    visualDensity: VisualDensity.compact,
                                  ),
                                  icon: const Icon(
                                    Icons.graphic_eq_rounded,
                                    size: 22,
                                  ),
                                ),
                              const SizedBox(width: 4),
                              ValueListenableBuilder<TextEditingValue>(
                                valueListenable: controller,
                                builder: (context, value, _) {
                                  final canSend = attachmentsReady &&
                                      (value.text.trim().isNotEmpty || hasAttachments);
                                  return Tooltip(
                                    message: isLoading
                                        ? 'Parar geração'
                                        : 'Enviar mensagem',
                                    child: AnimatedScale(
                                      duration: reducedMotion
                                          ? Duration.zero
                                          : const Duration(milliseconds: 210),
                                      curve: Curves.easeOutBack,
                                      scale: (canSend || isLoading) ? 1 : 0.88,
                                      child: Material(
                                        color: isLoading
                                            ? palette.accent.withValues(
                                                alpha: 0.55,
                                              )
                                            : canSend
                                            ? palette.accent
                                            : palette.surfaceHover,
                                        borderRadius: BorderRadius.circular(14),
                                        elevation: canSend && !isLoading
                                            ? 3
                                            : 0,
                                        shadowColor: palette.accentGlow,
                                        child: InkWell(
                                          borderRadius: BorderRadius.circular(
                                            14,
                                          ),
                                          onTap: isLoading
                                              ? () {
                                                  HapticFeedback.lightImpact();
                                                  onStop?.call();
                                                }
                                              : canSend
                                              ? () {
                                                  HapticFeedback.lightImpact();
                                                  onSend();
                                                }
                                              : null,
                                          child: SizedBox(
                                            width: 40,
                                            height: 40,
                                            child: AnimatedSwitcher(
                                              duration: reducedMotion
                                                  ? Duration.zero
                                                  : const Duration(
                                                      milliseconds: 160,
                                                    ),
                                              child: Icon(
                                                key: ValueKey(isLoading),
                                                isLoading
                                                    ? Icons.stop_rounded
                                                    : Icons
                                                          .arrow_upward_rounded,
                                                color: Colors.white,
                                                size: isLoading ? 22 : 20,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
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
    final g = context.gama;

    return Material(
      color: g.surfaceCard,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        borderRadius: BorderRadius.circular(20),
        splashColor: g.accent.withValues(alpha: 0.08),
        highlightColor: g.accent.withValues(alpha: 0.04),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: g.border, width: 1.15),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: g.textPrimary),
              const SizedBox(width: 5),
              Text(
                label,
                style: TextStyle(
                  color: g.textPrimary,
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
