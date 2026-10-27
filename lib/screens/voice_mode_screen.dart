import 'dart:async';

import 'package:flutter/material.dart';
import '../widgets/gama_floating_page.dart';
import 'package:flutter/services.dart';

import '../core/gama_colors.dart';
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

  @override
  void initState() {
    super.initState();
    // Atualiza somente a camada visual: o áudio é gerenciado pela ChatScreen.
    _updateTimer = Timer.periodic(const Duration(milliseconds: 80), (_) {
      if (!mounted) return;
      final target = widget.isListening()
          ? widget.soundLevel().clamp(0.0, 1.0).toDouble()
          : (widget.isSpeaking() ? 0.35 : 0.0);
      // Filtro exponencial: remove picos sem atrasar excessivamente a reação.
      _visualLevel +=
          (target - _visualLevel) * (target > _visualLevel ? 0.31 : 0.16);
      if ((_visualLevel - target).abs() < 0.003) _visualLevel = target;
      setState(() {});
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
        ? 'Gama está falando'
        : processing
        ? 'Gama está pensando'
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
        actions: const [],
        showBack: false,
        leading: IconButton(
          tooltip: 'Encerrar conversa por voz',
          icon: const Icon(Icons.close_rounded),
          onPressed: () => Navigator.of(context).pop(),
        ),
        child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 28),
          child: Column(
            children: [
              const Spacer(),
              Center(
                child: GamaOrb(
                  size: MediaQuery.sizeOf(context).width < 450 ? 235 : 285,
                  intensity: reduceMotion ? 0.0 : _visualLevel,
                ),
              ),
              const SizedBox(height: 26),
              Semantics(
                liveRegion: true,
                child: AnimatedSwitcher(
                  duration: reduceMotion
                      ? Duration.zero
                      : const Duration(milliseconds: 180),
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
                        size: 17,
                      ),
                      const SizedBox(width: 9),
                      Flexible(
                        child: Text(
                          status,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: palette.textPrimary,
                            fontSize: 20,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                height: 86,
                child: Center(
                  child: AnimatedSwitcher(
                    duration: reduceMotion
                        ? Duration.zero
                        : const Duration(milliseconds: 160),
                    child: Text(
                      text.isEmpty ? 'Fale naturalmente com a Gama…' : text,
                      key: ValueKey<bool>(text.isEmpty),
                      textAlign: TextAlign.center,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: palette.textSecondary,
                        fontSize: 14,
                        height: 1.5,
                      ),
                    ),
                  ),
                ),
              ),
              const Spacer(),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
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
                  const SizedBox(width: 22),
                  _VoiceAction(
                    icon: Icons.close_rounded,
                    label: 'Encerrar',
                    onTap: () async {
                      await HapticFeedback.lightImpact();
                      if (context.mounted) Navigator.of(context).pop();
                    },
                    primary: true,
                  ),
                  if (speaking || preparingSpeech || processing) ...[
                    const SizedBox(width: 22),
                    _VoiceAction(
                      icon: Icons.stop_rounded,
                      label: 'Interromper',
                      onTap: _interrupt,
                      primary: false,
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      )
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
      label: label,
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
                  color: primary ? Colors.white : g.textPrimary,
                  size: 27,
                ),
              ),
            ),
          ),
          const SizedBox(height: 9),
          Text(label, style: TextStyle(fontSize: 12, color: g.textSecondary)),
        ],
      ),
    );
  }
}
