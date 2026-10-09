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
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Column(
            children: [
              const Spacer(flex: 2),
              Image.asset(
                'assets/images/image3.png',
                width: 64,
                height: 64,
                fit: BoxFit.contain,
              ),
              const SizedBox(height: 20),
              const Text(
                'Gamma 2.0',
                style: TextStyle(
                  color: GamaColors.textPrimary,
                  fontSize: 28,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Entre para sincronizar sua memória\ne personalizar a experiência.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: GamaColors.textSecondary,
                  fontSize: 15,
                  height: 1.4,
                ),
              ),
              const Spacer(flex: 2),
              if (_error != null) ...[
                Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: GamaColors.error, fontSize: 13),
                ),
                const SizedBox(height: 16),
              ],
              SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton(
                  onPressed: _loading ? null : _onGoogle,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: Colors.black87,
                    disabledBackgroundColor: Colors.white24,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    elevation: 0,
                  ),
                  child: _loading
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.g_mobiledata, size: 28),
                            SizedBox(width: 8),
                            Text(
                              'Continuar com Google',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                ),
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: _loading ? null : _onGuest,
                child: const Text(
                  'Continuar como convidado',
                  style: TextStyle(color: GamaColors.textMuted, fontSize: 14),
                ),
              ),
              const SizedBox(height: 32),
              const Text(
                'A memória de longo prazo fica ligada a esta conta.',
                textAlign: TextAlign.center,
                style: TextStyle(color: GamaColors.textMuted, fontSize: 12),
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}
