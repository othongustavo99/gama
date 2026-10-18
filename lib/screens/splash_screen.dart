import 'dart:async';

import 'package:flutter/material.dart';

import '../core/gama_colors.dart';
import '../services/auth_service.dart';
import '../services/identity_service.dart';
import 'home_screen.dart';
import 'login_screen.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    // tempo mínimo da splash visual
    await Future.delayed(const Duration(seconds: 2));
    await IdentityService.instance.init();
    final sessionValid = await AuthService.instance.trySilentGoogle();

    if (!mounted) return;

    final next = sessionValid ? const HomeScreen() : const LoginScreen();

    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => next,
        transitionDuration: const Duration(milliseconds: 500),
        transitionsBuilder: (_, animation, __, child) {
          return FadeTransition(opacity: animation, child: child);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.gama.background,
      body: Stack(
        fit: StackFit.expand,
        children: [
          Image.asset(
            'assets/images/image.jpeg',
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => const ColoredBox(color: Colors.black),
          ),
          Positioned(
            bottom: 53,
            left: 0,
            right: 0,
            child: Center(
              child: SizedBox(
                width: 32,
                height: 32,
                child: CircularProgressIndicator(
                  strokeWidth: 3,
                  valueColor: AlwaysStoppedAnimation<Color>(
                    context.gama.accent,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
