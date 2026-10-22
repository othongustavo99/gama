import 'package:flutter/material.dart';

/// Transição curta e consistente; não anima com redução de movimento ativada.
class GamaPageRoute<T> extends PageRouteBuilder<T> {
  GamaPageRoute({required WidgetBuilder builder, RouteSettings? settings})
    : super(
        settings: settings,
        pageBuilder: (context, animation, secondaryAnimation) =>
            builder(context),
        transitionDuration: const Duration(milliseconds: 260),
        reverseTransitionDuration: const Duration(milliseconds: 190),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          if (MediaQuery.of(context).disableAnimations) return child;
          final curved = CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic,
          );
          return FadeTransition(
            opacity: curved,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0.035, 0.014),
                end: Offset.zero,
              ).animate(curved),
              child: child,
            ),
          );
        },
      );
}
