import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/gama_colors.dart';

BeveledRectangleBorder gamaCyberpunkBorder({
  BorderSide side = BorderSide.none,
  double cut = 12,
}) => BeveledRectangleBorder(
  side: side,
  borderRadius: BorderRadius.only(
    topLeft: Radius.circular(cut),
    bottomRight: Radius.circular(cut),
  ),
);

class GamaCyberpunkBackdrop extends StatelessWidget {
  const GamaCyberpunkBackdrop({super.key, required this.child});

  static const topColor = Color(0xFF35191D);

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final palette = context.gama;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (palette.isCyberpunk)
          Positioned.fill(
            child: IgnorePointer(
              child: RepaintBoundary(
                child: CustomPaint(
                  painter: _BackdropPainter(
                    accent: palette.accent,
                    background: palette.background,
                    keyboardOpen: MediaQuery.viewInsetsOf(context).bottom > 0,
                    topInset: MediaQuery.paddingOf(context).top,
                  ),
                ),
              ),
            ),
          ),
        KeyedSubtree(key: const ValueKey('page-content'), child: child),
      ],
    );
  }
}

class _BackdropPainter extends CustomPainter {
  const _BackdropPainter({
    required this.accent,
    required this.background,
    required this.keyboardOpen,
    required this.topInset,
  });

  final Color accent;
  final Color background;
  final bool keyboardOpen;
  final double topInset;

  @override
  void paint(Canvas canvas, Size size) {
    final bounds = Offset.zero & size;
    canvas.drawRect(
      bounds,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            GamaCyberpunkBackdrop.topColor,
            const Color(0xFF20161C),
            background,
          ],
          stops: const [0, .47, .87],
        ).createShader(bounds),
    );
    final top = topInset + 103;
    final bottom = size.height - 28;
    if (bottom < top + 48 || size.width < 220) return;

    canvas.save();
    canvas.clipRect(bounds);
    final rail = Paint()
      ..color = accent.withValues(alpha: .30)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawPath(
      Path()
        ..moveTo(7, top)
        ..lineTo(7, top + 18)
        ..lineTo(12, top + 23)
        ..lineTo(12, bottom - 28)
        ..lineTo(7, bottom - 23)
        ..lineTo(7, bottom),
      rail,
    );
    var index = 0;
    for (var y = top + 30; y < bottom - 30; y += 9) {
      final tick = index++ % 5 == 0 ? 8.0 : 4.0;
      canvas.drawLine(Offset(11 - tick, y), Offset(11, y), rail);
    }

    final right = size.width - 8;
    final rightBottom = top + math.min(185.0, (bottom - top) * .52);
    canvas.drawPath(
      Path()
        ..moveTo(size.width, top)
        ..lineTo(right, top + 8)
        ..lineTo(right, rightBottom)
        ..lineTo(size.width, rightBottom + 8),
      rail,
    );
    for (var y = top + 15; y < rightBottom; y += 7) {
      canvas.drawLine(Offset(right + 3, y), Offset(size.width, y - 4), rail);
    }

    if (!keyboardOpen) {
      final center = Offset(size.width - 30, size.height - 86);
      final rings = Paint()
        ..color = const Color(0xFF356269).withValues(alpha: .24)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5;
      final radius = math.min(size.width * .34, 182.0);
      for (var i = 0; i < 3; i++) {
        final ring = Rect.fromCircle(center: center, radius: radius - i * 13);
        canvas.drawArc(ring, .7 + i * .26, 2.02, false, rings);
        canvas.drawArc(ring, 3.04, 2.78 - i * .36, false, rings);
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _BackdropPainter oldDelegate) =>
      oldDelegate.accent != accent ||
      oldDelegate.background != background ||
      oldDelegate.keyboardOpen != keyboardOpen ||
      oldDelegate.topInset != topInset;
}

class GamaCyberpunkHeaderRule extends StatelessWidget {
  const GamaCyberpunkHeaderRule({super.key});

  static const height = 18.0;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: SizedBox(
      height: height,
      child: CustomPaint(painter: _HeaderRulePainter(context.gama.accent)),
    ),
  );
}

class _HeaderRulePainter extends CustomPainter {
  const _HeaderRulePainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final end = size.width;
    if (end < 120) return;
    final join = end * .54;
    final paint = Paint()
      ..color = color.withValues(alpha: .62)
      ..style = PaintingStyle.stroke;
    canvas.drawPath(
      Path()
        ..moveTo(0, 4)
        ..lineTo(join - 12, 4)
        ..lineTo(join, 16)
        ..lineTo(end, 16)
        ..lineTo(end, 4),
      paint,
    );
    canvas.drawPath(
      Path()
        ..moveTo(join + 5, 13)
        ..lineTo(join + 1, 9)
        ..lineTo(end - 5, 9)
        ..lineTo(end - 5, 13)
        ..close(),
      Paint()..color = color.withValues(alpha: .30),
    );

    const widths = [2.0, 4.0, 1.0, 2.0, 1.0, 3.0, 5.0, 1.0, 2.0, 4.0, 2.0];
    var x = end - 5;
    final barcode = Paint()..color = color;
    for (final width in widths) {
      x -= width;
      canvas.drawRect(Rect.fromLTWH(x, 0, width, 6), barcode);
      x -= 2;
    }
  }

  @override
  bool shouldRepaint(covariant _HeaderRulePainter oldDelegate) =>
      oldDelegate.color != color;
}
