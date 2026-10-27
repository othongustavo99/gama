import 'package:flutter/material.dart';
import '../widgets/gama_floating_page.dart';

import 'account_deletion_screen.dart';
import 'commercial_screen.dart';

import '../core/gama_colors.dart';
import '../widgets/loading_skeleton.dart';
import '../services/memory_service.dart';
import '../services/ollama_service.dart';
import '../services/settings_service.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _urlController = TextEditingController();
  final _api = OllamaService();
  final _memory = MemoryService();

  bool _resettingMemory = false;

  bool _testing = false;
  bool _saving = false;
  String? _statusMessage;
  bool? _statusOk;
  bool _ttsAuto = false;
  double _fontScale = 1.0;
  bool _developerMode = false;
  GamaAppearance _appearance = GamaAppearance.dark;
  bool _reduceMotion = false;

  @override
  void initState() {
    super.initState();
    _urlController.text = SettingsService.instance.baseUrl;
    _ttsAuto = SettingsService.instance.ttsAuto;
    _fontScale = SettingsService.instance.fontScale;
    _developerMode = SettingsService.instance.developerMode;
    _appearance = SettingsService.instance.appearance;
    _reduceMotion = SettingsService.instance.reduceMotion;
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _testConnection() async {
    if (_testing) return;
    setState(() {
      _testing = true;
      _statusMessage = null;
    });

    final previous = SettingsService.instance.baseUrl;
    var ok = false;
    try {
      await SettingsService.instance.setBaseUrl(_urlController.text);
      ok = await _api.ping();
    } catch (_) {
      ok = false;
    } finally {
      if (!ok) {
        await SettingsService.instance.setBaseUrl(previous);
        if (mounted) _urlController.text = previous;
      }
    }

    if (!mounted) return;
    setState(() {
      _testing = false;
      _statusOk = ok;
      _statusMessage = ok
          ? 'API online. Modelos e chat disponíveis.'
          : 'Falha ao conectar. O endereço anterior foi restaurado.';
    });
  }

  Future<void> _resetMemory() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: context.gama.surfaceCard,
        title: Text(
          'Resetar memória?',
          style: TextStyle(color: context.gama.textPrimary),
        ),
        content: Text(
          'Todos os fatos que a Gama guardou sobre você serão apagados. '
          'Essa ação não pode ser desfeita.',
          style: TextStyle(color: context.gama.textMuted, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: context.gama.error),
            child: const Text('Resetar'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _resettingMemory = true);
    String message;
    try {
      await _memory.clear();
      message = 'Memória resetada';
    } catch (e) {
      message = 'Não foi possível resetar a memória. Verifique a conexão.';
    }
    if (!mounted) return;
    setState(() => _resettingMemory = false);
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await SettingsService.instance.setBaseUrl(_urlController.text);
      await SettingsService.instance.setTtsAuto(_ttsAuto);
      await SettingsService.instance.setFontScale(_fontScale);
      await SettingsService.instance.setDeveloperMode(_developerMode);
      await SettingsService.instance.setAppearance(_appearance);
      await SettingsService.instance.setReduceMotion(_reduceMotion);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Não foi possível salvar as configurações.'),
        ));
      }
      return;
    } finally {
      if (mounted) setState(() => _saving = false);
    }

    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Configurações salvas')));
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.gama.background,
      
      body: GamaFloatingPage(
        actions: const [],
        child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
        children: [
          if (_developerMode) ...[
            const _SectionTitle('API'),
            const SizedBox(height: 10),
            TextField(
              controller: _urlController,
              style: TextStyle(color: context.gama.textPrimary, fontSize: 15),
              decoration: InputDecoration(
                hintText: 'https://sua-api.com',
                hintStyle: TextStyle(color: context.gama.textHint),
                filled: true,
                fillColor: context.gama.surfaceInput,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: context.gama.border),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: context.gama.border),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: context.gama.accent, width: 1.2),
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 14,
                ),
              ),
              keyboardType: TextInputType.url,
              autocorrect: false,
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _testing ? null : _testConnection,
                icon: _testing
                    ? const GamaSkeleton(width: 16, height: 16, radius: 8)
                    : const Icon(Icons.wifi_tethering_rounded, size: 18),
                label: Text(_testing ? 'Testando…' : 'Testar conexão'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: context.gama.textPrimary,
                  side: BorderSide(color: context.gama.border),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
            if (_statusMessage != null) ...[
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: (_statusOk == true)
                      ? context.gama.success.withValues(alpha: 0.12)
                      : context.gama.error.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: (_statusOk == true)
                        ? context.gama.success.withValues(alpha: 0.4)
                        : context.gama.error.withValues(alpha: 0.4),
                  ),
                ),
                child: Text(
                  _statusMessage!,
                  style: TextStyle(
                    color: (_statusOk == true)
                        ? context.gama.success
                        : context.gama.error,
                    fontSize: 13,
                    height: 1.35,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 28),
          ],
          const _SectionTitle('Modelo em uso'),
          const SizedBox(height: 8),
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            tileColor: context.gama.surfaceInput,
            leading: Icon(
              Icons.auto_awesome_rounded,
              color: context.gama.accent,
            ),
            title: Text(
              SettingsService.instance.mode == GamaMode.conversar
                  ? 'GPT-5.4 Mini'
                  : 'GLM 5.3 Flash',
              style: TextStyle(color: context.gama.textPrimary),
            ),
            subtitle: Text(
              'Altere o modo na tela principal. A Oficina usa o modelo da tarefa.',
              style: TextStyle(color: context.gama.textMuted, fontSize: 12),
            ),
          ),
          const SizedBox(height: 28),
          const _SectionTitle('Voz'),
          const SizedBox(height: 6),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(
              'Ler respostas automaticamente',
              style: TextStyle(color: context.gama.textPrimary, fontSize: 15),
            ),
            subtitle: Text(
              'TTS ao finalizar cada resposta do assistente',
              style: TextStyle(color: context.gama.textMuted, fontSize: 12),
            ),
            value: _ttsAuto,
            activeThumbColor: context.gama.accent,
            onChanged: (v) => setState(() => _ttsAuto = v),
          ),
          const SizedBox(height: 28),
          const _SectionTitle('Aparência e acessibilidade'),
          const SizedBox(height: 14),
          DropdownButtonFormField<GamaAppearance>(
            value: _appearance,
            decoration: const InputDecoration(
              labelText: 'Tema do aplicativo',
              helperText: 'Automático acompanha o tema do Android ou Windows.',
            ),
            items: const [
              DropdownMenuItem(
                value: GamaAppearance.system,
                child: Text('Automático (sistema)'),
              ),
              DropdownMenuItem(
                value: GamaAppearance.light,
                child: Text('Claro'),
              ),
              DropdownMenuItem(
                value: GamaAppearance.dark,
                child: Text('Escuro'),
              ),
            ],
            onChanged: (value) async {
              if (value == null) return;
              setState(() => _appearance = value);
              await SettingsService.instance.setAppearance(value);
            },
          ),
          const SizedBox(height: 16),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('Reduzir animações'),
            subtitle: const Text(
              'Diminui movimentos no chat e nas transições; também respeita o sistema.',
            ),
            value: _reduceMotion,
            onChanged: (value) async {
              setState(() => _reduceMotion = value);
              await SettingsService.instance.setReduceMotion(value);
            },
          ),
          const SizedBox(height: 14),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Tamanho do texto'),
              Text('${(_fontScale * 100).round()}%',
                  style: TextStyle(color: context.gama.textSecondary)),
            ],
          ),
          Slider.adaptive(
            min: 0.85,
            max: 1.30,
            divisions: 9,
            label: '${(_fontScale * 100).round()}%',
            value: _fontScale.clamp(0.85, 1.30).toDouble(),
            onChanged: (value) => setState(() => _fontScale = value),
            onChangeEnd: SettingsService.instance.setFontScale,
          ),
          Text(
            'Combina este ajuste com o tamanho de texto do sistema.',
            style: TextStyle(color: context.gama.textMuted, fontSize: 12),
          ),
          const SizedBox(height: 28),
          const _SectionTitle('Desenvolvedor'),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(
              'Mostrar detalhes técnicos',
              style: TextStyle(color: context.gama.textPrimary, fontSize: 15),
            ),
            subtitle: Text(
              'Mostra a conexão com o servidor e informações avançadas para diagnóstico.',
              style: TextStyle(color: context.gama.textMuted, fontSize: 12),
            ),
            value: _developerMode,
            activeThumbColor: context.gama.accent,
            onChanged: (value) async {
              setState(() => _developerMode = value);
              await SettingsService.instance.setDeveloperMode(value);
            },
          ),
          const SizedBox(height: 28),
          const _SectionTitle('Memória'),
          const SizedBox(height: 6),
          Text(
            'Apaga tudo o que a Gama lembra sobre você (nome, preferências, '
            'projetos…).',
            style: TextStyle(
              color: context.gama.textMuted,
              fontSize: 12,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _resettingMemory ? null : _resetMemory,
              icon: _resettingMemory
                  ? const GamaSkeleton(width: 16, height: 16, radius: 8)
                  : const Icon(Icons.delete_sweep_rounded, size: 18),
              label: Text(_resettingMemory ? 'Resetando…' : 'Resetar memória'),
              style: OutlinedButton.styleFrom(
                foregroundColor: context.gama.error,
                side: BorderSide(
                  color: context.gama.error.withValues(alpha: 0.5),
                ),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
          const SizedBox(height: 32),
          const _SectionTitle('Plano e utilização'),
          const SizedBox(height: 8),
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 12),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            tileColor: context.gama.surfaceInput,
            leading: Icon(Icons.workspace_premium_outlined, color: context.gama.accent),
            title: const Text('Meu plano e consumo'),
            subtitle: const Text('Consulte suas franquias beta e créditos internos.'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const CommercialScreen()),
            ),
          ),
          const SizedBox(height: 28),
          const _SectionTitle('Conta e privacidade'),
          const SizedBox(height: 8),
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 12),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            tileColor: context.gama.surfaceInput,
            leading: Icon(Icons.privacy_tip_outlined, color: context.gama.textSecondary),
            title: const Text('Gerenciar e excluir conta'),
            subtitle: const Text('Exclusão definitiva do histórico, memória e arquivos associados.'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const AccountDeletionScreen()),
            ),
          ),
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _saving ? null : _save,
              style: ElevatedButton.styleFrom(
                backgroundColor: context.gama.accent,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 16),
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: Text(
                _saving ? 'Salvando…' : 'Salvar',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
            ),
          ),
          const SizedBox(height: 20),
          if (_developerMode) Text(
            'Emulador Android: http://10.0.2.2:8000\n'
            'Celular físico: IP da máquina onde a API está rodando.\n'
            'Release: use sempre HTTPS.',
            style: TextStyle(
              color: context.gama.textMuted,
              fontSize: 12,
              height: 1.45,
            ),
          ),
        ],
      )
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 3,
          height: 14,
          decoration: BoxDecoration(
            color: context.gama.accent,
            borderRadius: BorderRadius.circular(3),
          ),
        ),
        const SizedBox(width: 9),
        Text(
          text.toUpperCase(),
          style: TextStyle(
            color: context.gama.textSecondary,
            fontSize: 12,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.9,
          ),
        ),
      ],
    );
  }
}
