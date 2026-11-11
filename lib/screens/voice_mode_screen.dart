import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../core/constants.dart';
import '../widgets/gama_floating_page.dart';
import 'package:flutter/services.dart';

import '../core/gama_colors.dart';
import '../core/design_tokens.dart';
import '../widgets/gama_orb.dart';

/// Casca visual do modo voz. STT, TTS e envio continuam no ChatScreen,
/// sem iniciar sessões paralelas ou duplicar chamadas aos provedores.
class VoiceModeScreen extends StatefulWidget {
  final bool Function() isListening;
  final bool Function()? isReconnecting;
  final bool Function() isSpeaking;
  final bool Function()? isPreparingSpeech;
  final bool Function() isProcessing;
  final double Function() soundLevel;
  final String Function() transcript;
  final Future<void> Function() onToggleMic;
  final Future<void> Function() onInterrupt;

  const VoiceModeScreen({
    super.key,
    required this.isListening,
    this.isReconnecting,
    required this.isSpeaking,
    this.isPreparingSpeech,
    required this.isProcessing,
    required this.soundLevel,
    required this.transcript,
    required this.onToggleMic,
    required this.onInterrupt,
  });

  @override
  State<VoiceModeScreen> createState() => _VoiceModeScreenState();
}

class _VoiceModeScreenState extends State<VoiceModeScreen> {
  Timer? _updateTimer;
  bool _busy = false;
  double _visualLevel = 0;
  bool _showFullTranscript = false;
  String _lastVoiceSnapshot = '';

  @override
  void initState() {
    super.initState();
    // Atualiza somente a camada visual: o áudio é gerenciado pela ChatScreen.
    _updateTimer = Timer.periodic(const Duration(milliseconds: 120), (_) {
      if (!mounted) return;
      final listening = widget.isListening();
      final speaking = widget.isSpeaking();
      final target = listening
          ? widget.soundLevel().clamp(0.0, 1.0).toDouble()
          : (speaking ? 0.35 : 0.0);
      final previous = _visualLevel;
      _visualLevel += (target - _visualLevel) *
          (target > _visualLevel ? 0.38 : 0.22);
      if ((_visualLevel - target).abs() < 0.008) _visualLevel = target;
      final snapshot = '${listening}|${widget.isReconnecting?.call()}|'
          '$speaking|${widget.isPreparingSpeech?.call()}|'
          '${widget.isProcessing()}|${widget.transcript()}';
      if (snapshot != _lastVoiceSnapshot ||
          (previous - _visualLevel).abs() > 0.008) {
        _lastVoiceSnapshot = snapshot;
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _updateTimer?.cancel();
    super.dispose();
  }

  Future<void> _mic() async {
    if (_busy) return;
    setState(() => _busy = true);
    await HapticFeedback.selectionClick();
    try {
      await widget.onToggleMic();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Não foi possível alterar o microfone. Tente novamente.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _interrupt() async {
    await HapticFeedback.lightImpact();
    try {
      await widget.onInterrupt();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Não foi possível interromper o áudio.'),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.gama;
    final listening = widget.isListening();
    final reconnecting = widget.isReconnecting?.call() ?? false;
    final speaking = widget.isSpeaking();
    final preparingSpeech = widget.isPreparingSpeech?.call() ?? false;
    final processing = widget.isProcessing();
    final text = widget.transcript().trim();
    final reduceMotion = MediaQuery.of(context).disableAnimations;
    final status = speaking
        ? '$kAppName está falando'
        : processing
        ? '$kAppName está pensando'
        : preparingSpeech
        ? 'Preparando voz…'
        : listening
        ? 'Estou ouvindo'
        : reconnecting
        ? 'Restabelecendo microfone…'
        : 'Microfone desligado';

    return Scaffold(
      backgroundColor: palette.background,
      body: GamaFloatingPage(
        showBack: false,
        leading: IconButton(
          tooltip: 'Encerrar conversa por voz',
          icon: const Icon(Icons.close_rounded),
          onPressed: () => Navigator.of(context).pop(),
        ),
        child: SafeArea(
          top: false, // O cabeçalho flutuante já reserva a barra de status.
          child: LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxHeight < 620;
              final orbSize = math.min(
                compact ? 185.0 : 248.0,
                math.min(constraints.maxWidth * 0.77,
                    math.max(128.0, constraints.maxHeight * 0.38)),
              );
              final topSpace = math.max(12.0,
                  (constraints.maxHeight - orbSize - 275) / 3);
              return SingleChildScrollView(
                keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(height: topSpace),
                      Center(
                        child: GamaOrb(
                          size: orbSize,
                          intensity: reduceMotion ? 0.0 : _visualLevel,
                        ),
                      ),
                      SizedBox(height: compact ? 16 : 24),
                      Semantics(
                        liveRegion: true,
                        child: AnimatedSwitcher(
                          duration: reduceMotion
                              ? Duration.zero
                              : GamaMotion.fast,
                          child: Row(
                            key: ValueKey<String>(status),
                            mainAxisAlignment: MainAxisAlignment.center,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                reconnecting
                                    ? Icons.sync_rounded
                                    : listening
                                        ? Icons.mic_rounded
                                        : speaking
                                            ? Icons.graphic_eq_rounded
                                            : processing
                                                ? Icons.auto_awesome_rounded
                                                : preparingSpeech
                                                    ? Icons.hourglass_top_rounded
                                                    : Icons.mic_off_rounded,
                                color: palette.accent,
                                size: 19,
                              ),
                              const SizedBox(width: 9),
                              Flexible(
                                child: Text(
                                  status,
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontWeight: FontWeight.w600,
                                    color: palette.textPrimary,
                                    fontSize: GamaType.section,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      Container(
                        constraints: const BoxConstraints(maxWidth: 620),
                        alignment: Alignment.center,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                        decoration: BoxDecoration(
                          color: palette.surfaceCard,
                          borderRadius: BorderRadius.circular(GamaRadius.lg),
                          border: Border.all(color: palette.borderSoft),
                        ),
                        child: Column(
                          children: [
                            if (text.isEmpty)
                              Text(
                                'Fale naturalmente com a $kAppName…',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: palette.textSecondary,
                                  fontSize: GamaType.secondary,
                                  height: 1.45,
                                ),
                              )
                            else if (_showFullTranscript)
                              ConstrainedBox(
                                constraints: const BoxConstraints(maxHeight: 180),
                                child: SingleChildScrollView(
                                  child: SelectableText(
                                    text,
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: palette.textSecondary,
                                      fontSize: GamaType.secondary,
                                      height: 1.5,
                                    ),
                                  ),
                                ),
                              )
                            else
                              Text(
                                text,
                                textAlign: TextAlign.center,
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: palette.textSecondary,
                                  fontSize: GamaType.secondary,
                                  height: 1.5,
                                ),
                              ),
                            if (text.length > 130) ...[
                              const SizedBox(height: 3),
                              TextButton(
                                onPressed: () => setState(
                                    () => _showFullTranscript = !_showFullTranscript),
                                child: Text(_showFullTranscript
                                    ? 'Recolher transcrição'
                                    : 'Ler transcrição completa'),
                              ),
                            ],
                          ],
                        ),
                      ),
                      SizedBox(height: compact ? 18 : 32),
                      Wrap(
                        alignment: WrapAlignment.center,
                        spacing: 8,
                        runSpacing: 12,
                        children: [
                          _VoiceAction(
                            icon: (listening || reconnecting)
                                ? Icons.mic_off_rounded
                                : Icons.mic_rounded,
                            label: (listening || reconnecting)
                                ? 'Silenciar'
                                : 'Ativar microfone',
                            onTap: _busy ? null : _mic,
                            primary: false,
                          ),
                          _VoiceAction(
                            icon: Icons.close_rounded,
                            label: 'Encerrar',
                            onTap: () async {
                              await HapticFeedback.lightImpact();
                              if (context.mounted) Navigator.of(context).pop();
                            },
                            primary: true,
                          ),
                          if (speaking || preparingSpeech || processing)
                            _VoiceAction(
                              icon: Icons.stop_rounded,
                              label: 'Interromper',
                              onTap: _interrupt,
                              primary: false,
                            ),
                        ],
                      ),
                      SizedBox(height: compact ? 8 : 20),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _VoiceAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool primary;

  const _VoiceAction({
    required this.icon,
    required this.label,
    required this.onTap,
    required this.primary,
  });

  @override
  Widget build(BuildContext context) {
    final g = context.gama;
    return Semantics(
      button: true,
      enabled: onTap != null,
      label: label,
      child: SizedBox(
        width: 91,
        child: Column(
        children: [
          Material(
            color: primary ? g.accent : g.surfaceCard,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onTap,
              child: SizedBox.square(
                dimension: 64,
                child: Icon(
                  icon,
                  color: primary ? g.onAccent : g.textPrimary,
                  size: 27,
                ),
              ),
            ),
          ),
          const SizedBox(height: 9),
          Text(
            label,
            maxLines: 2,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: GamaType.label, color: g.textSecondary),
          ),
        ],
        ),
      ),
    );
  }
}
