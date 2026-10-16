import 'package:flutter/material.dart';

import '../core/gama_colors.dart';
import '../services/auth_service.dart';
import '../services/identity_service.dart';
import '../services/memory_service.dart';
import 'home_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  bool _loading = false;
  String? _error;

  Future<void> _goHome() async {
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => const HomeScreen(),
        transitionDuration: const Duration(milliseconds: 400),
        transitionsBuilder: (_, animation, __, child) {
          return FadeTransition(opacity: animation, child: child);
        },
      ),
    );
  }

  Future<void> _onGoogle() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final ok = await AuthService.instance.signInWithGoogle();
      if (!mounted) return;
      if (ok) {
        // Unifica memória legada (google_<id>) → google_email_* entre Android/Windows
        try {
          await MemoryService().migrateIfNeeded();
        } catch (_) {}
        await _goHome();
      } else {
        setState(() {
          _loading = false;
          _error = 'Login cancelado';
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error =
            'Falha no Google Sign-In.\n'
            'Confira SHA-1 e OAuth no Google Cloud.\n$e';
      });
    }
  }

  Future<void> _onGuest() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    await IdentityService.instance.continueAsGuest();
    if (!mounted) return;
    await _goHome();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: GamaColors.background,
      body: Stack(
        children: [
          Positioned(
            top: -100,
            right: -90,
            child: Container(
              width: 300,
              height: 300,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [GamaColors.accent.withOpacity(0.14), Colors.transparent],
                ),
              ),
            ),
          ),
          Positioned(
            bottom: -150,
            left: -90,
            child: Container(
              width: 340,
              height: 340,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [GamaColors.accentCool.withOpacity(0.08), Colors.transparent],
                ),
              ),
            ),
          ),
          SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) => Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: 430,
                      minHeight: constraints.maxHeight > 48
                          ? constraints.maxHeight - 48
                          : 0,
                    ),
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(24, 30, 24, 24),
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [GamaColors.surfaceElevated, GamaColors.surface],
                        ),
                        borderRadius: BorderRadius.circular(28),
                        border: Border.all(color: GamaColors.borderSoft),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.25),
                            blurRadius: 32,
                            offset: const Offset(0, 16),
                          ),
                        ],
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Container(
                            width: 78,
                            height: 78,
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: GamaColors.surfaceCard,
                              borderRadius: BorderRadius.circular(24),
                              border: Border.all(color: GamaColors.border),
                              boxShadow: [
                                BoxShadow(
                                  color: GamaColors.accent.withOpacity(0.13),
                                  blurRadius: 24,
                                ),
                              ],
                            ),
                            child: Image.asset(
                              'assets/images/image3.png',
                              fit: BoxFit.contain,
                            ),
                          ),
                          const SizedBox(height: 20),
                          const Text(
                            'Gama',
                            style: TextStyle(
                              color: GamaColors.textPrimary,
                              fontSize: 29,
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.8,
                            ),
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            'Seu espaço para programar, criar\ne conversar com inteligência.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: GamaColors.textSecondary,
                              fontSize: 14,
                              height: 1.55,
                            ),
                          ),
                          const SizedBox(height: 28),
                          if (_error != null) ...[
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(13),
                              decoration: BoxDecoration(
                                color: GamaColors.error.withOpacity(0.10),
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(
                                  color: GamaColors.error.withOpacity(0.28),
                                ),
                              ),
                              child: Text(
                                _error!,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: GamaColors.error,
                                  fontSize: 12,
                                  height: 1.4,
                                ),
                              ),
                            ),
                            const SizedBox(height: 14),
                          ],
                          SizedBox(
                            width: double.infinity,
                            height: 54,
                            child: ElevatedButton(
                              onPressed: _loading ? null : _onGoogle,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.white,
                                foregroundColor: const Color(0xFF202124),
                                disabledBackgroundColor: Colors.white24,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(16),
                                ),
                                elevation: 0,
                              ),
                              child: _loading
                                  ? const SizedBox(
                                      width: 22,
                                      height: 22,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Row(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        Icon(Icons.g_mobiledata, size: 28),
                                        SizedBox(width: 8),
                                        Text(
                                          'Continuar com Google',
                                          style: TextStyle(
                                            fontSize: 15,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ],
                                    ),
                            ),
                          ),
                          const SizedBox(height: 10),
                          SizedBox(
                            width: double.infinity,
                            height: 50,
                            child: OutlinedButton(
                              onPressed: _loading ? null : _onGuest,
                              style: OutlinedButton.styleFrom(
                                foregroundColor: GamaColors.textPrimary,
                                side: const BorderSide(color: GamaColors.border),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(16),
                                ),
                              ),
                              child: const Text('Continuar como convidado'),
                            ),
                          ),
                          const SizedBox(height: 20),
                          const Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.lock_outline_rounded,
                                size: 13,
                                color: GamaColors.textMuted,
                              ),
                              SizedBox(width: 7),
                              Flexible(
                                child: Text(
                                  'A memória fica vinculada à sua conta.',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    color: GamaColors.textMuted,
                                    fontSize: 11,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
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
