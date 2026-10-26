import 'package:flutter/material.dart';

import '../core/gama_colors.dart';
import '../core/launch_policy.dart';
import '../widgets/loading_skeleton.dart';
import '../services/auth_service.dart';
import '../services/account_privacy_service.dart';
import '../services/identity_service.dart';
import '../services/memory_service.dart';
import 'home_screen.dart';
import '../utils/error_logger.dart';

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
        // Verificação ANTES de migrar memória ou exibir dados da conta.
        // Uma sessão antiga em outro aparelho não reativa uma conta apagada.
        final accountStatus = await AccountPrivacyService.instance.status();
        if (accountStatus == 'deleted') {
          // Histórico Hive e biblioteca são locais e compartilhados entre
          // sessões; jamais sincronizar dados da conta apagada em outra conta.
          await AccountPrivacyService.instance.clearDeviceAfterDeletion(
            keepGoogleSession: true,
          );
          if (!mounted) return;
          final restart = await showDialog<bool>(
            context: context,
            barrierDismissible: false,
            builder: (dialogContext) => AlertDialog(
              title: const Text('Conta excluída anteriormente'),
              content: const Text(
                'Os dados desta conta foram apagados. Você pode iniciar uma '
                'nova conta vazia usando o mesmo Google. Seu histórico antigo '
                'não será recuperado. Deseja recomeçar?'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: const Text('Cancelar')),
                FilledButton(
                  onPressed: () => Navigator.pop(dialogContext, true),
                  child: const Text('Recomeçar vazia')),
              ],
            ),
          );
          if (restart != true) {
            await AuthService.instance.signOut();
            if (mounted) setState(() { _loading = false; _error = null; });
            return;
          }
          await AccountPrivacyService.instance.startNewAccount();
        } else if (accountStatus != 'active') {
          throw StateError('A exclusão dos dados ainda está em processamento. '
              'Tente novamente mais tarde.');
        }
        // Unifica memória legada (google_<id>) → google_email_* entre Android/Windows
        try {
          await MemoryService().migrateIfNeeded();
        } catch (error, stack) {
          logSwallowed(error, stack);
        }
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
    if (!GamaLaunchPolicy.guestLoginEnabled) return;
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
      backgroundColor: context.gama.background,
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
                  colors: [
                    context.gama.accent.withValues(alpha: 0.14),
                    Colors.transparent,
                  ],
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
                  colors: [
                    context.gama.accentCool.withValues(alpha: 0.08),
                    Colors.transparent,
                  ],
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
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            context.gama.surfaceElevated,
                            context.gama.surface,
                          ],
                        ),
                        borderRadius: BorderRadius.circular(28),
                        border: Border.all(color: context.gama.borderSoft),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.25),
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
                              color: context.gama.surfaceCard,
                              borderRadius: BorderRadius.circular(24),
                              border: Border.all(color: context.gama.border),
                              boxShadow: [
                                BoxShadow(
                                  color: context.gama.accent.withValues(
                                    alpha: 0.13,
                                  ),
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
                          Text(
                            'Gama',
                            style: TextStyle(
                              color: context.gama.textPrimary,
                              fontSize: 29,
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.8,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Seu espaço para programar, criar\ne conversar com inteligência.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: context.gama.textSecondary,
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
                                color: context.gama.error.withValues(
                                  alpha: 0.10,
                                ),
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(
                                  color: context.gama.error.withValues(
                                    alpha: 0.28,
                                  ),
                                ),
                              ),
                              child: Text(
                                _error!,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: context.gama.error,
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
                                  ? const GamaSkeleton(
                                      width: 22,
                                      height: 22,
                                      radius: 11,
                                      baseColor: Color(0x33FFFFFF),
                                      highlightColor: Color(0x99FFFFFF),
                                    )
                                  : const Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
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
                          if (GamaLaunchPolicy.guestLoginEnabled) ...[
                            const SizedBox(height: 10),
                            SizedBox(
                              width: double.infinity,
                              height: 50,
                              child: OutlinedButton(
                                onPressed: _loading ? null : _onGuest,
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: context.gama.textPrimary,
                                  side: BorderSide(color: context.gama.border),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                ),
                                child: const Text(
                                  'Convidado (somente desenvolvimento)',
                                ),
                              ),
                            ),
                          ],
                          const SizedBox(height: 20),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.lock_outline_rounded,
                                size: 13,
                                color: context.gama.textMuted,
                              ),
                              SizedBox(width: 7),
                              Flexible(
                                child: Text(
                                  'A memória fica vinculada à sua conta.',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    color: context.gama.textMuted,
                                    fontSize: 12,
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
