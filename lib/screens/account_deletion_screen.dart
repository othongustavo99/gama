import 'package:flutter/material.dart';
import '../widgets/gama_floating_page.dart';

import '../core/gama_colors.dart';
import '../services/account_privacy_service.dart';
import '../services/auth_service.dart';
import '../services/identity_service.dart';
import 'login_screen.dart';

class AccountDeletionScreen extends StatefulWidget {
  const AccountDeletionScreen({super.key});

  @override
  State<AccountDeletionScreen> createState() => _AccountDeletionScreenState();
}

class _AccountDeletionScreenState extends State<AccountDeletionScreen> {
  final TextEditingController _confirmation = TextEditingController();
  bool _busy = false;
  String? _error;
  bool _serverDeleted = false;

  @override
  void dispose() {
    _confirmation.dispose();
    super.dispose();
  }

  Future<void> _delete() async {
    if (_busy || _confirmation.text.trim() != 'EXCLUIR') return;
    setState(() { _busy = true; _error = null; });
    try {
      // Não apaga dados locais antes da confirmação do backend.
      await AccountPrivacyService.instance.deleteAccount();
      _serverDeleted = true;
    } catch (error) {
      if (!mounted) return;
      setState(() { _busy = false; _error = '$error'; });
      return;
    }
    await _finishLocalPurge();
  }

  Future<void> _finishLocalPurge() async {
    if (!mounted) return;
    setState(() { _busy = true; _error = null; });
    try {
      await AccountPrivacyService.instance.clearDeviceAfterDeletion();
      await AuthService.instance.signOut();
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const LoginScreen()), (_) => false);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Os dados do servidor foram excluídos, mas houve uma falha '
            'na limpeza deste aparelho. Toque em tentar novamente. '
            'Detalhes: $error';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final google = IdentityService.instance.provider == 'google';
    return Scaffold(
      backgroundColor: context.gama.background,
      
      body: GamaFloatingPage(
        actions: const [],
        child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Icon(Icons.shield_outlined, color: context.gama.accent, size: 36),
          const SizedBox(height: 14),
          const Text('Sua conta e seus dados', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          const Text('Apagar apenas a memória não exclui a conta. Aqui você pode '
              'solicitar a exclusão definitiva dos dados associados à sua identidade Google.'),
          const SizedBox(height: 20),
          const Text('Serão excluídos do servidor: conversas, memória, resumos, '
              'projetos temporários, arquivos gerados, histórico de vídeos e cotas '
              'vinculadas à conta.'),
          const SizedBox(height: 12),
          const Text('Também serão apagados neste dispositivo: histórico local, '
              'rascunhos, biblioteca e arquivos internos do aplicativo. '
              'Os dados locais de outras contas autenticadas serão preservados.'),
          const SizedBox(height: 12),
          const Text('Arquivos que você exportou para Downloads ou outros locais '
              'fora do aplicativo não serão excluídos. Backups externos e dados '
              'sujeitos a retenção legal dependem da política publicada.'),
          const SizedBox(height: 22),
          if (!google) const Text('Entre com sua conta Google para solicitar a exclusão.'),
          if (google && !_serverDeleted) ...[
            TextField(
              controller: _confirmation,
              onChanged: (_) => setState(() {}),
              enabled: !_busy,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(
                labelText: 'Digite EXCLUIR para confirmar',
                hintText: 'EXCLUIR',
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _confirmation.text.trim() == 'EXCLUIR' && !_busy ? _delete : null,
              icon: _busy
                  ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.delete_forever_outlined),
              label: Text(_busy ? 'Excluindo conta...' : 'Excluir definitivamente minha conta'),
              style: FilledButton.styleFrom(backgroundColor: context.gama.error),
            ),
          ],
          if (_serverDeleted) ...[
            const SizedBox(height: 14),
            OutlinedButton.icon(
              onPressed: _busy ? null : _finishLocalPurge,
              icon: const Icon(Icons.refresh_rounded),
              label: Text(_busy ? 'Limpando dispositivo...' : 'Tentar limpar este dispositivo novamente'),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            SelectableText(_error!, style: TextStyle(color: context.gama.error)),
          ],
        ],
      )
      ),
    );
  }
}
