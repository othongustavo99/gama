import 'dart:collection';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/scheduler.dart';

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
    if (!isLoading &&
        attachmentsReady &&
        (controller.text.trim().isNotEmpty || hasAttachments)) {
      onSend();
    }
  }

  Future<void> _showMediaSettings(BuildContext context) async {
    final isVideo = oficinaKind == OficinaKind.video;
    var ratio = isVideo ? videoAspectRatio : imageAspectRatio;
    var style = imageStyle;
    var duration = videoDuration;
    var resolution = videoResolution;
    var audio = videoGenerateAudio;

    final applied = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) => SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * .82,
            ),
            child: ListView(
              primary: false,
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
              children: [
                Text(
                  isVideo ? 'Ajustes de vídeo' : 'Ajustes de imagem',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                _MediaOptions(
                  title: 'Proporção',
                  options: const ['1:1', '16:9', '9:16'],
                  selected: ratio,
                  label: (value) => value,
                  onSelected: (value) => setSheetState(() => ratio = value),
                ),
                if (isVideo) ...[
                  _MediaOptions(
                    title: 'Duração',
                    options: const [5, 10, 15],
                    selected: duration,
                    label: (value) => '${value}s',
                    onSelected: (value) =>
                        setSheetState(() => duration = value),
                  ),
                  _MediaOptions(
                    title: 'Resolução',
                    options: const ['480p', '720p'],
                    selected: resolution,
                    label: (value) => value,
                    onSelected: (value) =>
                        setSheetState(() => resolution = value),
                  ),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Áudio'),
                    value: audio,
                    onChanged: (value) => setSheetState(() => audio = value),
                  ),
                ] else
                  _MediaOptions(
                    title: 'Estilo',
                    options: const ['Automático', 'Foto', 'Ilustração', '3D'],
                    selected: style,
                    label: (value) => value,
                    onSelected: (value) => setSheetState(() => style = value),
                  ),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Aplicar ajustes'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (applied != true || !context.mounted) return;
    if (isVideo) {
      if (ratio != videoAspectRatio) onVideoAspectRatioChanged?.call(ratio);
      if (duration != videoDuration) onVideoDurationChanged?.call(duration);
      if (resolution != videoResolution)
        onVideoResolutionChanged?.call(resolution);
      if (audio != videoGenerateAudio) onVideoGenerateAudioChanged?.call(audio);
    } else {
      if (ratio != imageAspectRatio) onImageAspectRatioChanged?.call(ratio);
      if (style != imageStyle) onImageStyleChanged?.call(style);
    }
  }

  @override
  Widget build(BuildContext context) {
    final shortcuts = <ShortcutActivator, Intent>{
      if (_usesDesktopEnterShortcut) ...{
        // Enter envia; Shift+Enter permanece livre para inserir nova linha.
        const SingleActivator(LogicalKeyboardKey.enter):
            const _SendMessageIntent(),
        const SingleActivator(LogicalKeyboardKey.numpadEnter):
            const _SendMessageIntent(),
      },
    };

    final slashCommands =
        <(String, String)>[
              ('/memoria', 'Consultar fatos salvos'),
              ('/memoria limpar', 'Apagar fatos salvos'),
              ('/memoria ', 'Salvar um fato na memória'),
              ('/limpar', 'Limpar esta conversa'),
              if (oficinaKind == null) ...[
                ('/modo programar', 'Mudar para Programar'),
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
    final bottomGap = !kIsWeb && defaultTargetPlatform == TargetPlatform.android
        ? 3.0
        : 12.0;
    return AnimatedBuilder(
      animation: focusNode ?? controller,
      builder: (context, child) {
        final focused = focusNode?.hasFocus ?? false;
        return SafeArea(
          top: false,
          child: Padding(
            padding: EdgeInsets.fromLTRB(12, 10, 12, bottomGap),
            child: _ComposerSurface(
              highlighted: focused || isListening,
              child: Padding(
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
                    if (oficinaKind == OficinaKind.imagem ||
                        oficinaKind == OficinaKind.video)
                      Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 8,
                        children: [
                          TextButton.icon(
                            onPressed: isLoading
                                ? null
                                : () => _showMediaSettings(context),
                            icon: const Icon(Icons.tune_rounded, size: 18),
                            label: const Text('Ajustes'),
                          ),
                          Text(
                            oficinaKind == OficinaKind.video
                                ? '$videoAspectRatio · ${videoDuration}s · $videoResolution'
                                : '$imageAspectRatio · $imageStyle',
                            style: TextStyle(
                              color: palette.textSecondary,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    if (showSlashMenu && slashCommands.isNotEmpty)
                      Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        constraints: const BoxConstraints(maxHeight: 190),
                        child: Material(
                          color: context.gama.surfaceCard,
                          shape: RoundedRectangleBorder(
                            side: BorderSide(color: context.gama.border),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: ListView(
                            primary: false,
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
                                  onTap: () =>
                                      onSlashCommandSelected?.call(command.$1),
                                ),
                            ],
                          ),
                        ),
                      ),
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
                            textCapitalization: TextCapitalization.sentences,
                            decoration: InputDecoration(
                              hintText: isListening
                                  ? 'Ouvindo… o texto aparece aqui'
                                  : placeholder ?? 'Escreva sua mensagem...',
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
                    // Ferramentas responsivas: no celular estreito os
                    // controles ficam em duas linhas, sem reduzir a area
                    // de toque ou ocultar a conversa por voz.
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final scaledLabel = MediaQuery.textScalerOf(context)
                            .scale(14);
                        final compact =
                            constraints.maxWidth <
                                (oficinaKind == null ? 356 : 402) ||
                            scaledLabel > 17;
                        final actions = <Widget>[
                          IconButton(
                            onPressed: isLoading
                                ? null
                                : () {
                                    HapticFeedback.selectionClick();
                                    onAttach();
                                  },
                            tooltip: 'Anexar arquivo ou imagem',
                            constraints: const BoxConstraints(
                              minWidth: 44,
                              minHeight: 44,
                            ),
                            padding: EdgeInsets.zero,
                            color: context.gama.textSecondary,
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
                              tooltip: isListening
                                  ? 'Parar ditado'
                                  : 'Ditar mensagem',
                              constraints: const BoxConstraints(
                                minWidth: 44,
                                minHeight: 44,
                              ),
                              padding: EdgeInsets.zero,
                              color: isListening
                                  ? context.gama.accent
                                  : context.gama.textSecondary,
                              icon: Icon(
                                isListening
                                    ? Icons.mic
                                    : Icons.mic_none_rounded,
                                size: 22,
                              ),
                            ),
                          ),
                          // A conversa por voz deve estar disponível
                          // também por teclado, toque e leitor de tela;
                          // nao apenas por long press no microfone.
                          if (onOpenVoice != null)
                            IconButton(
                              onPressed: isLoading
                                  ? null
                                  : () {
                                      HapticFeedback.selectionClick();
                                      onOpenVoice!();
                                    },
                              tooltip: 'Abrir conversa por voz',
                              constraints: const BoxConstraints(
                                minWidth: 44,
                                minHeight: 44,
                              ),
                              padding: EdgeInsets.zero,
                              color: context.gama.textSecondary,
                              icon: const Icon(
                                Icons.record_voice_over_outlined,
                                size: 22,
                              ),
                            ),
                          if (oficinaKind == null)
                            ValueListenableBuilder<TextEditingValue>(
                              valueListenable: controller,
                              builder: (context, value, _) {
                                final canSpeakSend =
                                    !isLoading &&
                                    attachmentsReady &&
                                    (value.text.trim().isNotEmpty ||
                                        hasAttachments);
                                return IconButton(
                                  onPressed: !canSpeakSend
                                      ? null
                                      : () {
                                          HapticFeedback.lightImpact();
                                          onSpeakSend();
                                        },
                                  tooltip: 'Enviar e ouvir resposta',
                                  constraints: const BoxConstraints(
                                    minWidth: 44,
                                    minHeight: 44,
                                  ),
                                  padding: EdgeInsets.zero,
                                  color: context.gama.accent,
                                  icon: const Icon(
                                    Icons.graphic_eq_rounded,
                                    size: 22,
                                  ),
                                );
                              },
                            ),
                          ValueListenableBuilder<TextEditingValue>(
                            valueListenable: controller,
                            builder: (context, value, _) {
                              final canSend =
                                  attachmentsReady &&
                                  (value.text.trim().isNotEmpty ||
                                      hasAttachments);
                              final actionEnabled = isLoading
                                  ? onStop != null
                                  : canSend;
                              return Tooltip(
                                message: isLoading
                                    ? 'Parar geração'
                                    : canSend
                                    ? 'Enviar mensagem'
                                    : attachmentsReady
                                    ? 'Digite uma mensagem para enviar'
                                    : 'Aguarde os anexos',
                                child: Semantics(
                                  button: true,
                                  enabled: actionEnabled,
                                  label: isLoading
                                      ? 'Parar geração'
                                      : 'Enviar mensagem',
                                  child: AnimatedScale(
                                    duration: reducedMotion
                                        ? Duration.zero
                                        : const Duration(milliseconds: 210),
                                    curve: Curves.easeOutBack,
                                    scale: (canSend || isLoading) ? 1 : 0.92,
                                    child: Material(
                                      color: isLoading
                                          ? palette.surfaceHover
                                          : canSend
                                          ? palette.accent
                                          : palette.surfaceHover,
                                      borderRadius: BorderRadius.circular(14),
                                      elevation: canSend && !isLoading ? 3 : 0,
                                      shadowColor: palette.accentGlow,
                                      child: InkWell(
                                        borderRadius: BorderRadius.circular(14),
                                        canRequestFocus: actionEnabled,
                                        onTap: isLoading
                                            ? onStop == null
                                                  ? null
                                                  : () {
                                                      HapticFeedback.lightImpact();
                                                      onStop!();
                                                    }
                                            : canSend
                                            ? () {
                                                HapticFeedback.lightImpact();
                                                _submitIfPossible();
                                              }
                                            : null,
                                        child: SizedBox(
                                          width: 44,
                                          height: 44,
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
                                                  : Icons.arrow_upward_rounded,
                                              color: isLoading
                                                  ? palette.textPrimary
                                                  : canSend
                                                      ? palette.onAccent
                                                      : palette.textMuted,
                                              size: isLoading ? 22 : 20,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ];
                        final modeChip = _ModeChip(
                          label: oficinaKind == null
                              ? 'Oficina'
                              : '${oficinaKind!.label}  ×',
                          icon: oficinaKind?.icon ?? Icons.handyman_rounded,
                          selected: true,
                          onTap: oficinaKind == null
                              ? () => Navigator.of(context).push(
                                  GamaPageRoute<void>(
                                    builder: (_) => const OficinaScreen(),
                                  ),
                                )
                              : (onExitOficina ?? () {}),
                        );
                        if (compact) {
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              modeChip,
                              const SizedBox(height: 4),
                              Align(
                                alignment: Alignment.centerRight,
                                child: Wrap(
                                  alignment: WrapAlignment.end,
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  spacing: 2,
                                  runSpacing: 2,
                                  children: actions,
                                ),
                              ),
                            ],
                          );
                        }
                        return Row(
                          children: [modeChip, const Spacer(), ...actions],
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _MediaOptions<T> extends StatelessWidget {
  const _MediaOptions({
    required this.title,
    required this.options,
    required this.selected,
    required this.label,
    required this.onSelected,
  });

  final String title;
  final List<T> options;
  final T selected;
  final String Function(T) label;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final option in options)
              ChoiceChip(
                label: Text(label(option)),
                selected: option == selected,
                onSelected: (_) => onSelected(option),
              ),
          ],
        ),
      ],
    ),
  );
}

class _ComposerSurface extends StatefulWidget {
  const _ComposerSurface({required this.highlighted, required this.child});

  final bool highlighted;
  final Widget child;

  @override
  State<_ComposerSurface> createState() => _ComposerSurfaceState();
}

class _ComposerSurfaceState extends State<_ComposerSurface> {
  final Queue<bool> _slowFrames = Queue<bool>();
  bool _monitoring = false;
  bool _solidForPerformance = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _monitorFrames(
      !kIsWeb &&
          defaultTargetPlatform == TargetPlatform.android &&
          !MediaQuery.disableAnimationsOf(context) &&
          !_solidForPerformance,
    );
  }

  void _monitorFrames(bool enabled) {
    if (_monitoring == enabled) return;
    _monitoring = enabled;
    final scheduler = SchedulerBinding.instance;
    if (enabled) {
      scheduler.addTimingsCallback(_onFrameTimings);
    } else {
      scheduler.removeTimingsCallback(_onFrameTimings);
      _slowFrames.clear();
    }
  }

  void _onFrameTimings(List<FrameTiming> timings) {
    if (!mounted) return;
    final refreshRate = View.of(context).display.refreshRate;
    final budget = Duration(
      microseconds: (1000000 / (refreshRate > 0 ? refreshRate : 60)).round(),
    );
    for (final timing in timings) {
      if (_slowFrames.length == 8) _slowFrames.removeFirst();
      _slowFrames.add(
        timing.buildDuration > budget || timing.rasterDuration > budget,
      );
      if (_slowFrames.length == 8 &&
          _slowFrames.where((slow) => slow).length >= 3) {
        setState(() => _solidForPerformance = true);
        _monitorFrames(false);
        return;
      }
    }
  }

  @override
  void dispose() {
    _monitorFrames(false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.gama;
    final solid =
        _solidForPerformance || MediaQuery.disableAnimationsOf(context);
    final surface = DecoratedBox(
      decoration: BoxDecoration(
        color: solid
            ? palette.surfaceCard
            : palette.surfaceCard.withValues(alpha: .88),
        borderRadius: BorderRadius.circular(23),
        border: Border.all(
          color: widget.highlighted ? palette.accent : palette.border,
        ),
      ),
      child: widget.child,
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(23),
      child: solid
          ? surface
          : BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 7, sigmaY: 7),
              child: surface,
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
