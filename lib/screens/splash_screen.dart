import 'dart:async';

import 'package:flutter/material.dart';

import '../core/gama_colors.dart';
import '../widgets/gama_brand_mark.dart';
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
    final g = context.gama;
    return Scaffold(
      backgroundColor: g.background,
      body: SafeArea(
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Uma única composição responsiva, sem recortar a imagem vertical
            // em janelas largas ou em dispositivos com formatos incomuns.
            Positioned(
              left: -110,
              top: -130,
              child: IgnorePointer(
                child: Container(
                  width: 340,
                  height: 340,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(colors: [
                      g.accentGlow,
                      g.background.withValues(alpha: 0),
                    ]),
                  ),
                ),
              ),
            ),
            Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const GamaBrandMark(size: 96),
                      const SizedBox(height: 24),
                      Text('Gamma',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: g.textPrimary, fontSize: 30,
                          fontWeight: FontWeight.w700, letterSpacing: -0.7),
                      ),
                      const SizedBox(height: 9),
                      Text('Converse, crie e trabalhe com inteligência.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: g.textSecondary, fontSize: 14,
                          height: 1.5),
                      ),
                      const SizedBox(height: 34),
                      SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.1,
                          color: g.accent,
                          semanticsLabel: 'Preparando a Gamma',
                        ),
                      ),
                      const SizedBox(height: 11),
                      Text('Preparando seu espaço',
                        style: TextStyle(color: g.textMuted, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
