import 'package:flutter/material.dart';

import '../core/constants.dart';
import '../core/gama_colors.dart';
import '../core/gama_page_route.dart';
import '../services/memory_service.dart';
import '../services/ollama_service.dart';
import '../services/settings_service.dart';
import '../utils/friendly_error.dart';
import '../widgets/gama_floating_page.dart';
import 'account_screen.dart';
import 'commercial_screen.dart';
import 'memory_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = SettingsService.instance;
    return _SettingsPage(
      title: 'Configurações',
      children: [
        _pageLink(
          context,
          Icons.palette_outlined,
          'Aparência',
          const _AppearanceSettings(),
        ),
        _pageLink(
          context,
          Icons.record_voice_over_outlined,
          'Voz',
          const _VoiceSettings(),
        ),
        _pageLink(
          context,
          Icons.psychology_outlined,
          'Memória',
          const _MemorySettings(),
        ),
        _pageLink(
          context,
          Icons.workspace_premium_outlined,
          'Plano',
          const CommercialScreen(),
        ),
        _pageLink(
          context,
          Icons.person_outline_rounded,
          'Conta',
          const AccountScreen(),
        ),
        const Divider(),
        ListenableBuilder(
          listenable: settings,
          builder: (context, _) => ListTile(
            leading: const Icon(Icons.auto_awesome_outlined),
            title: Text(
              settings.mode == GamaMode.conversar ? 'Conversar' : 'Programar',
            ),
            subtitle: const Text('Altere o modo na tela principal.'),
          ),
        ),
      ],
    );
  }
}

Widget _pageLink(
  BuildContext context,
  IconData icon,
  String title,
  Widget page,
) {
  return ListTile(
    leading: Icon(icon, color: context.gama.accent),
    title: Text(title),
    trailing: const Icon(Icons.chevron_right_rounded),
    onTap: () =>
        Navigator.of(context).push(GamaPageRoute<void>(builder: (_) => page)),
  );
}

class _SettingsPage extends StatelessWidget {
  const _SettingsPage({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: context.gama.background,
    body: GamaFloatingPage(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 660),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Semantics(
                  header: true,
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                ),
              ),
              ...children,
            ],
          ),
        ),
      ),
    ),
  );
}

Future<void> _savePreference(
  BuildContext context,
  Future<void> Function() save,
) async {
  try {
    await save();
  } catch (error, stack) {
    showFriendlyError(
      context.mounted ? context : null,
      error,
      stack,
      acao: 'salvar a preferência',
    );
  }
}

class _AppearanceSettings extends StatefulWidget {
  const _AppearanceSettings();

  @override
  State<_AppearanceSettings> createState() => _AppearanceSettingsState();
}

class _AppearanceSettingsState extends State<_AppearanceSettings> {
  double? _fontPreview;

  @override
  Widget build(BuildContext context) {
    final settings = SettingsService.instance;
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        final fontScale = _fontPreview ?? settings.fontScale;
        return _SettingsPage(
          title: 'Aparência',
          children: [
            DropdownButtonFormField<GamaAppearance>(
              initialValue: settings.appearance,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Tema do aplicativo',
                helperText: 'Automático acompanha o tema do sistema.',
                helperMaxLines: 2,
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
              onChanged: (value) {
                if (value != null) {
                  _savePreference(context, () => settings.setAppearance(value));
                }
              },
            ),
            const SizedBox(height: 16),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('Reduzir animações'),
              subtitle: const Text(
                'Diminui o movimento e usa um fundo sólido no campo de mensagem.',
              ),
              value: settings.reduceMotion,
              onChanged: (value) => _savePreference(
                context,
                () => settings.setReduceMotion(value),
              ),
            ),
            const SizedBox(height: 16),
            Text('Tamanho do texto · ${(fontScale * 100).round()}%'),
            Slider.adaptive(
              min: .85,
              max: 1.30,
              divisions: 9,
              label: '${(fontScale * 100).round()}%',
              value: fontScale,
              onChanged: (value) => setState(() => _fontPreview = value),
              onChangeEnd: (value) async {
                await _savePreference(
                  context,
                  () => settings.setFontScale(value),
                );
                if (mounted) setState(() => _fontPreview = null);
              },
            ),
            Text(
              'Combina este ajuste com o tamanho de texto do sistema.',
              style: TextStyle(color: context.gama.textMuted, fontSize: 12),
            ),
            const Divider(height: 32),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('Mostrar detalhes técnicos'),
              subtitle: const Text(
                'Libera os ajustes de conexão com o servidor.',
              ),
              value: settings.developerMode,
              onChanged: (value) => _savePreference(
                context,
                () => settings.setDeveloperMode(value),
              ),
            ),
            if (settings.developerMode)
              _pageLink(
                context,
                Icons.dns_outlined,
                'Conexão com a API',
                const _ApiSettings(),
              ),
          ],
        );
      },
    );
  }
}

class _VoiceSettings extends StatelessWidget {
  const _VoiceSettings();

  @override
  Widget build(BuildContext context) {
    final settings = SettingsService.instance;
    return _SettingsPage(
      title: 'Voz',
      children: [
        ListenableBuilder(
          listenable: settings,
          builder: (context, _) => SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('Ler respostas automaticamente'),
            subtitle: const Text('Inicia a leitura ao final de cada resposta.'),
            value: settings.ttsAuto,
            onChanged: (value) =>
                _savePreference(context, () => settings.setTtsAuto(value)),
          ),
        ),
      ],
    );
  }
}

class _MemorySettings extends StatefulWidget {
  const _MemorySettings();

  @override
  State<_MemorySettings> createState() => _MemorySettingsState();
}

class _MemorySettingsState extends State<_MemorySettings> {
  bool _resetting = false;

  Future<void> _resetMemory() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Resetar memória?'),
        content: const Text(
          'Todos os fatos que a $kAppName guardou sobre você serão apagados. Essa ação não pode ser desfeita.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Resetar'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _resetting = true);
    try {
      await MemoryService().clear();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Memória resetada')));
      }
    } catch (error, stack) {
      showFriendlyError(
        mounted ? context : null,
        error,
        stack,
        acao: 'resetar a memória',
      );
    } finally {
      if (mounted) setState(() => _resetting = false);
    }
  }

  @override
  Widget build(BuildContext context) => _SettingsPage(
    title: 'Memória',
    children: [
      _pageLink(
        context,
        Icons.list_alt_outlined,
        'Ver memórias salvas',
        const MemoryScreen(),
      ),
      const SizedBox(height: 16),
      OutlinedButton.icon(
        onPressed: _resetting ? null : _resetMemory,
        icon: const Icon(Icons.delete_sweep_outlined),
        label: Text(_resetting ? 'Resetando…' : 'Resetar memória'),
        style: OutlinedButton.styleFrom(foregroundColor: context.gama.error),
      ),
    ],
  );
}

class _ApiSettings extends StatefulWidget {
  const _ApiSettings();

  @override
  State<_ApiSettings> createState() => _ApiSettingsState();
}

class _ApiSettingsState extends State<_ApiSettings> {
  final _formKey = GlobalKey<FormState>();
  late final _controller = TextEditingController(
    text: SettingsService.instance.baseUrl,
  );
  bool _busy = false;
  bool? _online;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _test() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _online = null;
    });
    final online = await OllamaService().ping(baseUrl: _controller.text.trim());
    if (!mounted) return;
    setState(() {
      _busy = false;
      _online = online;
    });
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _busy = true);
    try {
      await SettingsService.instance.setBaseUrl(_controller.text);
      if (mounted) Navigator.of(context).pop();
    } catch (error, stack) {
      showFriendlyError(
        mounted ? context : null,
        error,
        stack,
        acao: 'salvar o endereço da API',
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => _SettingsPage(
    title: 'Conexão com a API',
    children: [
      Form(
        key: _formKey,
        child: TextFormField(
          controller: _controller,
          enabled: !_busy,
          keyboardType: TextInputType.url,
          autocorrect: false,
          decoration: const InputDecoration(labelText: 'Endereço do servidor'),
          onChanged: (_) {
            if (_online != null) setState(() => _online = null);
          },
          validator: (value) {
            final url = Uri.tryParse(value?.trim() ?? '');
            if (url == null ||
                !['http', 'https'].contains(url.scheme) ||
                url.host.isEmpty) {
              return 'Informe um endereço HTTP ou HTTPS válido.';
            }
            return null;
          },
        ),
      ),
      const SizedBox(height: 16),
      OutlinedButton.icon(
        onPressed: _busy ? null : _test,
        icon: const Icon(Icons.wifi_tethering_rounded),
        label: const Text('Testar conexão'),
      ),
      if (_online case final online?)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Text(
            online
                ? 'API disponível.'
                : 'Falha ao conectar. Confira o endereço e a rede.',
            style: TextStyle(
              color: online ? context.gama.success : context.gama.error,
            ),
          ),
        ),
      const SizedBox(height: 8),
      FilledButton(
        onPressed: _busy ? null : _save,
        child: const Text('Salvar endereço'),
      ),
    ],
  );
}
