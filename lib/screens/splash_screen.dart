import 'dart:async';

import 'package:flutter/material.dart';

import '../core/gama_colors.dart';
import '../widgets/gama_orb.dart';
import '../services/auth_service.dart';
import '../services/account_privacy_service.dart';
import '../services/identity_service.dart';
import '../services/conversation_service.dart';
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
    bool allowed = sessionValid;
    if (allowed && IdentityService.instance.provider == 'google') {
      try {
        final accountStatus = await AccountPrivacyService.instance.status();
        allowed = accountStatus == 'active';
        if (accountStatus == 'deleted') {
          // O titular pode ter excluído os dados por outro dispositivo.
          await AccountPrivacyService.instance.clearDeviceAfterDeletion();
          await AuthService.instance.signOut();
        }
      } catch (_) {
        // Sem confirmação do servidor, não abrir automaticamente dados de
        // uma sessão antiga que poderia ter sido excluída em outro aparelho.
        allowed = false;
      }
    }

    if (allowed) {
      await ConversationService.instance.activateForCurrentIdentity();
    }
    if (!mounted) return;

    final next = allowed ? const HomeScreen() : const LoginScreen();

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
            child: Center(child: const GamaOrb(size: 84)),
          ),
        ],
      ),
    );
  }
}
