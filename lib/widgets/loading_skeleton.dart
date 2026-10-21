import 'package:flutter/material.dart';

import '../core/gama_colors.dart';
import '../core/design_tokens.dart';

/// Subtle shimmer used for content that is still being fetched or prepared.
class GamaSkeleton extends StatefulWidget {
  final double? width;
  final double height;
  final double radius;
  final Color? baseColor;
  final Color? highlightColor;

  const GamaSkeleton({
    super.key,
    this.width,
    this.height = 14,
    this.radius = GamaRadius.md,
    this.baseColor,
    this.highlightColor,
  });

  @override
  State<GamaSkeleton> createState() => _GamaSkeletonState();
}

class _GamaSkeletonState extends State<GamaSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1350),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.gama;
    final base = widget.baseColor ?? palette.surfaceCard;
    final highlight = widget.highlightColor ?? palette.surfaceHover;
    return Semantics(
      label: 'Carregando',
      child: SizedBox(
        width: widget.width,
        height: widget.height,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(widget.radius),
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, _) => DecoratedBox(
              decoration: BoxDecoration(
                color: base,
                gradient: LinearGradient(
                  begin: Alignment(-1.5 + 3 * _controller.value, 0),
                  end: Alignment(-0.5 + 3 * _controller.value, 0),
                  colors: [base, highlight, base],
                  stops: const [0.35, 0.5, 0.65],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class GamaSkeletonList extends StatelessWidget {
  final int itemCount;
  final EdgeInsetsGeometry padding;
  final bool withLeading;

  const GamaSkeletonList({
    super.key,
    this.itemCount = 4,
    this.padding = const EdgeInsets.all(GamaSpace.lg),
    this.withLeading = true,
  });

  @override
  Widget build(BuildContext context) => ListView.separated(
    padding: padding,
    itemCount: itemCount,
    separatorBuilder: (_, __) => const SizedBox(height: GamaSpace.md),
    itemBuilder: (context, index) => Container(
      padding: const EdgeInsets.all(GamaSpace.md),
      decoration: BoxDecoration(
        color: context.gama.surfaceCard,
        borderRadius: BorderRadius.circular(GamaRadius.lg),
        border: Border.all(color: context.gama.borderSoft),
      ),
      child: Row(
        children: [
          if (withLeading) ...[
            const GamaSkeleton(width: 40, height: 40, radius: GamaRadius.md),
            const SizedBox(width: GamaSpace.md),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                GamaSkeleton(
                  width:
                      MediaQuery.sizeOf(context).width *
                      (index.isEven ? 0.46 : 0.58),
                  height: 14,
                ),
                const SizedBox(height: GamaSpace.sm),
                const GamaSkeleton(width: double.infinity, height: 11),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class GamaSkeletonGrid extends StatelessWidget {
  final int itemCount;
  final EdgeInsetsGeometry padding;

  const GamaSkeletonGrid({
    super.key,
    this.itemCount = 6,
    this.padding = const EdgeInsets.all(GamaSpace.lg),
  });

  @override
  Widget build(BuildContext context) => GridView.builder(
    padding: padding,
    itemCount: itemCount,
    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: 2,
      mainAxisSpacing: GamaSpace.md,
      crossAxisSpacing: GamaSpace.md,
      childAspectRatio: 0.9,
    ),
    itemBuilder: (_, __) =>
        const GamaSkeleton(height: double.infinity, radius: GamaRadius.lg),
  );
}
