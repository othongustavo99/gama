import 'package:flutter/material.dart';

import '../core/gama_colors.dart';
import '../core/gama_page_route.dart';
import '../services/identity_service.dart';
import '../widgets/gama_floating_page.dart';
import 'account_deletion_screen.dart';
import 'library_screen.dart';
import 'memory_screen.dart';

/// Ponto de entrada seguro para perfil, sessão e dados pessoais.
/// A exclusão fica propositalmente separada e não é executada nesta tela.
class AccountScreen extends StatelessWidget {
  const AccountScreen({super.key});

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
                    'Para sair ou trocar de conta, use o menu lateral.',
                  ),
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
