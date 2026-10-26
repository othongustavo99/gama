import 'package:flutter/material.dart';

import '../core/gama_colors.dart';
import '../core/design_tokens.dart';

/// Identidade visual usada na splash e no login.
/// A marca continua sendo o recurso já distribuído com o aplicativo.
class GamaBrandMark extends StatelessWidget {
  const GamaBrandMark({super.key, this.size = 80, this.label = 'Gamma'});

  final double size;
  final String label;

  @override
  Widget build(BuildContext context) {
    final g = context.gama;
    final radius = BorderRadius.circular(size > 70 ? GamaRadius.xl : GamaRadius.lg);
    return Semantics(
      label: 'Marca $label',
      image: true,
      child: Container(
        width: size,
        height: size,
        padding: EdgeInsets.all(size * 0.09),
        decoration: BoxDecoration(
          color: const Color(0xFF090909),
          borderRadius: radius,
          border: Border.all(color: g.borderSoft),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(GamaRadius.sm),
          child: Image.asset(
            'assets/images/image3.png',
            fit: BoxFit.contain,
            excludeFromSemantics: true,
            errorBuilder: (_, __, ___) => const Icon(
              Icons.auto_awesome_rounded,
              color: Colors.white,
            ),
          ),
        ),
      ),
    );
  }
}
