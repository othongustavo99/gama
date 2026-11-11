import 'package:flutter/material.dart';

import '../core/gama_colors.dart';
import '../core/gama_page_route.dart';
import '../services/identity_service.dart';
import '../services/auth_service.dart';
import '../utils/error_logger.dart';
import 'login_screen.dart';
import '../widgets/gama_floating_page.dart';
import 'account_deletion_screen.dart';
import 'library_screen.dart';
import 'memory_screen.dart';

/// Ponto de entrada seguro para perfil, sessão e dados pessoais.
/// A exclusão fica propositalmente separada e não é executada nesta tela.
class AccountScreen extends StatefulWidget {
  const AccountScreen({super.key});

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  bool _signingOut = false;

  Future<void> _confirmSignOut() async {
    if (_signingOut) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Sair da conta?'),
        content: const Text(
          'Você será direcionado para a tela de entrada. '
          'Sair não exclui suas conversas nem sua conta.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Sair'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _signingOut = true);
    try {
      await AuthService.instance.signOut();
    } catch (error, stack) {
      logSwallowed(error, stack, context: 'sair da conta');
      try {
        await IdentityService.instance.signOutLocal();
      } catch (fallbackError, fallbackStack) {
        logSwallowed(fallbackError, fallbackStack,
            context: 'encerrar sessão local');
        if (!mounted) return;
        setState(() => _signingOut = false);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Não foi possível encerrar a sessão. Tente novamente.'),
        ));
        return;
      }
    }
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      GamaPageRoute<void>(builder: (_) => const LoginScreen()),
      (_) => false,
    );
  }

  void _open(BuildContext context, Widget screen) {
    Navigator.of(context).push(GamaPageRoute<void>(builder: (_) => screen));
  }

  @override
  Widget build(BuildContext context) {
    final identity = IdentityService.instance;
    final isGoogle = identity.provider == 'google';
    final name = identity.displayName;
    final email = identity.email;
    final palette = context.gama;
    final firstLetter = name.trim().isEmpty
        ? 'G'
        : name.trim().substring(0, 1).toUpperCase();

    return Scaffold(
      backgroundColor: palette.background,
      body: GamaFloatingPage(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 660),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 36),
              children: [
                Semantics(
                  header: true,
                  child: Text('Conta e privacidade',
                      style: Theme.of(context).textTheme.headlineSmall),
                ),
                const SizedBox(height: 18),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: palette.surfaceCard,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: palette.borderSoft),
                  ),
                  child: Row(
                    children: [
                      CircleAvatar(
                        radius: 24,
                        backgroundColor: palette.accentSoft,
                        child: Text(firstLetter,
                            style: TextStyle(
                                fontSize: 19,
                                fontWeight: FontWeight.w700,
                                color: palette.accent)),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(name,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    color: palette.textPrimary,
                                    fontSize: 16,
                                    fontWeight: FontWeight.w700)),
                            const SizedBox(height: 4),
                            Text(
                              email != null && email.isNotEmpty
                                  ? email
                                  : isGoogle ? 'Conta Google' : 'Conta de convidado',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: palette.textSecondary),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 26),
                Text('SESSÃO',
                    style: TextStyle(
                      fontSize: 12,
                      letterSpacing: .8,
                      fontWeight: FontWeight.w700,
                      color: palette.textMuted,
                    )),
                const SizedBox(height: 8),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.verified_user_outlined,
                      color: palette.accent),
                  title: Text(isGoogle ? 'Conectado com Google' : 'Sessão de convidado'),
                  subtitle: const Text(
                    'Sua sessão atual está ativa neste dispositivo.',
                  ),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  key: const Key('account-sign-out'),
                  onPressed: _signingOut ? null : _confirmSignOut,
                  icon: _signingOut
                      ? const SizedBox(width: 18, height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.logout_rounded),
                  label: Text(_signingOut ? 'Saindo…' : 'Sair da conta'),
                ),
                const Divider(height: 32),
                Text('SEUS DADOS',
                    style: TextStyle(
                      fontSize: 12,
                      letterSpacing: .8,
                      fontWeight: FontWeight.w700,
                      color: palette.textMuted,
                    )),
                const SizedBox(height: 8),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.psychology_outlined,
                      color: palette.accent),
                  title: const Text('Memória'),
                  subtitle: const Text('Consulte e gerencie as informações lembradas.'),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => _open(context, const MemoryScreen()),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.folder_open_outlined,
                      color: palette.accent),
                  title: const Text('Biblioteca'),
                  subtitle: const Text('Consulte, salve ou remova arquivos locais.'),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => _open(context, const LibraryScreen()),
                ),
                const Divider(height: 32),
                Text('EXCLUSÃO DE CONTA',
                    style: TextStyle(
                      fontSize: 12,
                      letterSpacing: .8,
                      fontWeight: FontWeight.w700,
                      color: palette.textMuted,
                    )),
                const SizedBox(height: 10),
                Text(
                  'A exclusão definitiva é uma operação separada, com confirmação explícita. '
                  'Você pode continuar usando a Gamma sem fazer qualquer alteração aqui.',
                  style: TextStyle(color: palette.textSecondary, height: 1.45),
                ),
                const SizedBox(height: 14),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: () => _open(context, const AccountDeletionScreen()),
                    icon: const Icon(Icons.delete_outline_rounded),
                    label: const Text('Solicitar exclusão da conta'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: palette.error,
                      side: BorderSide(color: palette.error.withValues(alpha: .55)),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
