import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/gama_colors.dart';

/// Identidade visual da Gama. Não requer imagens, plugins ou rede.
/// Respeita a preferência de reduzir/desabilitar animações.
class GamaOrb extends StatefulWidget {
  final double size;
  final double intensity;
  final bool showCore;

  const GamaOrb({
    super.key,
    this.size = 112,
    this.intensity = 0,
    this.showCore = true,
  });

  @override
  State<GamaOrb> createState() => _GamaOrbState();
}

class _GamaOrbState extends State<GamaOrb> with SingleTickerProviderStateMixin {
  late final AnimationController _breath = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 3500),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.of(context).disableAnimations) {
      _breath.stop();
      _breath.value = 0.5;
    } else if (!_breath.isAnimating) {
      _breath.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _breath.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.gama;
    final intensity = widget.intensity.clamp(0.0, 1.0).toDouble();
    return Semantics(
      label: 'Aura da Gama',
      image: true,
      child: RepaintBoundary(
        child: SizedBox.square(
          dimension: widget.size,
          child: AnimatedBuilder(
            animation: _breath,
            builder: (context, _) {
              final breathe = math.sin(_breath.value * math.pi);
              final scale = 0.83 + breathe * 0.10 + intensity * 0.15;
              return Center(
                child: Transform.scale(
                  scale: scale,
                  child: Container(
                    width: widget.size * 0.68,
                    height: widget.size * 0.68,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        center: const Alignment(-0.34, -0.38),
                        radius: 0.95,
                        stops: const [0, 0.42, 0.77, 1],
                        colors: [
                          palette.accentBright,
                          palette.accent,
                          palette.accentMuted,
                          palette.accentCool,
                        ],
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: palette.accent.withValues(
                            alpha: 0.24 + intensity * 0.22,
                          ),
                          blurRadius: widget.size * (0.28 + intensity * 0.12),
                          spreadRadius: widget.size * 0.035,
                        ),
                        BoxShadow(
                          color: palette.accentCool.withValues(alpha: 0.18),
                          blurRadius: widget.size * 0.30,
                          offset: Offset(
                            widget.size * 0.08,
                            widget.size * 0.05,
                          ),
                        ),
                      ],
                    ),
                    child: widget.showCore
                        ? Center(
                            child: Container(
                              width: widget.size * 0.23,
                              height: widget.size * 0.23,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: Colors.white.withValues(alpha: 0.22),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.white.withValues(alpha: 0.27),
                                    blurRadius: widget.size * 0.12,
                                  ),
                                ],
                              ),
                            ),
                          )
                        : null,
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

/// Texto sutilmente iluminado, usado apenas enquanto a Gama trabalha.
class GamaShimmerText extends StatefulWidget {
  final String text;
  final TextStyle? style;

  const GamaShimmerText({super.key, required this.text, this.style});

  @override
  State<GamaShimmerText> createState() => _GamaShimmerTextState();
}

class _GamaShimmerTextState extends State<GamaShimmerText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1900),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.of(context).disableAnimations) {
      _animation.stop();
    } else if (!_animation.isAnimating) {
      _animation.repeat();
    }
  }

  @override
  void dispose() {
    _animation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = Text(
      widget.text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: widget.style,
    );
    if (MediaQuery.of(context).disableAnimations) return text;
    return AnimatedBuilder(
      animation: _animation,
      child: text,
      builder: (context, child) => ShaderMask(
        blendMode: BlendMode.srcIn,
        shaderCallback: (rect) => LinearGradient(
          begin: Alignment(-1.8 + _animation.value * 3.6, 0),
          end: Alignment(-0.8 + _animation.value * 3.6, 0),
          colors: [
            context.gama.textMuted,
            context.gama.accentBright,
            context.gama.textMuted,
          ],
          stops: const [0, 0.5, 1],
        ).createShader(rect),
        child: child,
      ),
    );
  }
}
