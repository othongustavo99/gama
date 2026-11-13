import 'dart:collection';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/scheduler.dart';

import '../core/gama_colors.dart';
import 'gama_cyberpunk_overlay.dart';
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
                    // Ferramentas principais numa linha. Ações de voz
                    // complementares ficam no menu explícito, acessível por
                    // toque, teclado e leitores de tela.
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final scaledLabel = MediaQuery.textScalerOf(context)
                            .scale(14);
                        final compact = constraints.maxWidth < 350 ||
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
                          IconButton(
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
                                ? palette.accent
                                : palette.textSecondary,
                            icon: Icon(
                              isListening
                                  ? Icons.mic
                                  : Icons.mic_none_rounded,
                              size: 22,
                            ),
                          ),
                          if (onOpenVoice != null || oficinaKind == null)
                            ValueListenableBuilder<TextEditingValue>(
                              valueListenable: controller,
                              builder: (context, value, _) {
                                final canSpeakSend =
                                    !isLoading && attachmentsReady &&
                                    (value.text.trim().isNotEmpty ||
                                        hasAttachments);
                                return PopupMenuButton<_ComposerVoiceAction>(
                                  tooltip: 'Opções de voz',
                                  enabled: !isLoading,
                                  color: palette.surfaceElevated,
                                  onSelected: (action) {
                                    HapticFeedback.selectionClick();
                                    switch (action) {
                                      case _ComposerVoiceAction.conversation:
                                        onOpenVoice?.call();
                                        break;
                                      case _ComposerVoiceAction.speakSend:
                                        if (canSpeakSend) onSpeakSend();
                                        break;
                                    }
                                  },
                                  itemBuilder: (context) => [
                                    if (onOpenVoice != null)
                                      const PopupMenuItem(
                                        value: _ComposerVoiceAction.conversation,
                                        child: ListTile(
                                          dense: true,
                                          contentPadding: EdgeInsets.zero,
                                          leading: Icon(Icons.headset_mic_outlined),
                                          title: Text('Abrir conversa por voz'),
                                        ),
                                      ),
                                    if (oficinaKind == null)
                                      PopupMenuItem(
                                        value: _ComposerVoiceAction.speakSend,
                                        enabled: canSpeakSend,
                                        child: const ListTile(
                                          dense: true,
                                          contentPadding: EdgeInsets.zero,
                                          leading: Icon(Icons.graphic_eq_rounded),
                                          title: Text('Enviar e ouvir resposta'),
                                        ),
                                      ),
                                  ],
                                  child: SizedBox(
                                    width: 44,
                                    height: 44,
                                    child: Center(
                                      child: Icon(
                                        Icons.headset_mic_outlined,
                                        size: 22,
                                        color: palette.textSecondary,
                                      ),
                                    ),
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
                                      shape: palette.isCyberpunk
                                          ? gamaCyberpunkBorder(cut: 9)
                                          : RoundedRectangleBorder(
                                              borderRadius: BorderRadius.circular(14),
                                            ),
                                      clipBehavior: palette.isCyberpunk
                                          ? Clip.antiAlias
                                          : Clip.none,
                                      elevation: canSend && !isLoading ? 3 : 0,
                                      shadowColor: palette.accentGlow,
                                      child: InkWell(
                                        customBorder: palette.isCyberpunk
                                            ? gamaCyberpunkBorder(cut: 9)
                                            : null,
                                        borderRadius: palette.isCyberpunk
                                            ? null
                                            : BorderRadius.circular(14),
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
                          iconOnly: compact,
                          onTap: oficinaKind == null
                              ? () => Navigator.of(context).push(
                                  GamaPageRoute<void>(
                                    builder: (_) => const OficinaScreen(),
                                  ),
                                )
                              : (onExitOficina ?? () {}),
                        );
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
          !context.gama.isCyberpunk &&
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
    if (palette.isCyberpunk) {
      return Material(
        color: palette.surfaceInput,
        shape: gamaCyberpunkBorder(
          side: BorderSide(
            color: widget.highlighted ? palette.accent : palette.border,
            width: widget.highlighted ? 1.6 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 9, 14, 0),
              child: SizedBox(
                height: 6,
                child: CustomPaint(
                  painter: _ComposerRulePainter(palette.accent),
                ),
              ),
            ),
            widget.child,
          ],
        ),
      );
    }
    final radius = BorderRadius.circular(23);
    final surface = DecoratedBox(
      decoration: BoxDecoration(
        color: solid
            ? palette.surfaceCard
            : palette.surfaceCard.withValues(alpha: .88),
        borderRadius: radius,
        border: Border.all(
          color: widget.highlighted ? palette.accent : palette.border,
        ),
      ),
      child: widget.child,
    );
    return ClipRRect(
      borderRadius: radius,
      child: solid
          ? surface
          : BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 7, sigmaY: 7),
              child: surface,
            ),
    );
  }
}

class _ComposerRulePainter extends CustomPainter {
  const _ComposerRulePainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height / 2;
    final line = Paint()..color = color.withValues(alpha: .32);
    canvas.drawLine(Offset(0, y), Offset(size.width, y), line);
    final marks = Paint()..color = color.withValues(alpha: .80);
    final left = (size.width * .12).clamp(0.0, 40.0);
    canvas.drawRect(Rect.fromLTWH(0, y - 1, left, 2), marks);
    for (var x = size.width - 36; x < size.width - 2; x += 5) {
      canvas.drawLine(Offset(x, 0), Offset(x - 3, size.height), marks);
    }
  }

  @override
  bool shouldRepaint(covariant _ComposerRulePainter oldDelegate) =>
      oldDelegate.color != color;
}

class _SendMessageIntent extends Intent {
  const _SendMessageIntent();
}

enum _ComposerVoiceAction { conversation, speakSend }

class _ModeChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final bool iconOnly;
  final VoidCallback onTap;

  const _ModeChip({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
    this.iconOnly = false,
  });

  @override
  Widget build(BuildContext context) {
    final g = context.gama;

    final shape = g.isCyberpunk
        ? gamaCyberpunkBorder(side: BorderSide(color: g.border), cut: 8)
        : RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(color: g.border, width: 1.15),
          );
    return Tooltip(
      message: label,
      child: Material(
        color: g.surfaceCard,
        shape: shape,
        child: InkWell(
          onTap: () {
            HapticFeedback.selectionClick();
            onTap();
          },
          customBorder: shape,
          splashColor: g.accent.withValues(alpha: 0.08),
          highlightColor: g.accent.withValues(alpha: 0.04),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: 11,
              vertical: iconOnly ? 11 : 7,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 14, color: g.textPrimary),
                if (!iconOnly) ...[
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
              ],
            ),
          ),
        ),
      ),
    );
  }
}
