import 'package:flutter/material.dart';

import '../core/constants.dart';
import '../core/gama_colors.dart';
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

  List<String> _models = [];
  String? _selectedModel;
  GamaMode _mode = GamaMode.programar;
  bool _loadingModels = false;
  bool _testing = false;
  String? _statusMessage;
  bool? _statusOk;
  bool _ttsAuto = false;
  ThemeMode _themeMode = ThemeMode.dark;
  double _fontScale = 1.0;
  bool _developerMode = false;

  @override
  void initState() {
    super.initState();
    _urlController.text = SettingsService.instance.baseUrl;
    _selectedModel = SettingsService.instance.model;
    _mode = SettingsService.instance.mode;
    _ttsAuto = SettingsService.instance.ttsAuto;
    _themeMode = SettingsService.instance.themeMode;
    _fontScale = SettingsService.instance.fontScale;
    _developerMode = SettingsService.instance.developerMode;
    _loadModels();
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _loadModels() async {
    setState(() {
      _loadingModels = true;
      _statusMessage = null;
    });

    try {
      final models = await _api.listModels();
      if (!mounted) return;

      final previousModel = SettingsService.instance.model;
      String? replacementModel;
      setState(() {
        _models = models;
        // Mantém o modelo atual se ainda estiver na lista; senão pega o primeiro
        if (_selectedModel != null && models.contains(_selectedModel)) {
          // ok
        } else if (models.isNotEmpty) {
          _selectedModel = models.first;
          replacementModel = _selectedModel;
        }
        _loadingModels = false;
      });
      if (replacementModel != null && replacementModel != previousModel) {
        await SettingsService.instance.setModel(replacementModel!);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingModels = false;
        // Fallback: mostra os modelos locais das constantes
        if (_models.isEmpty) {
          _models = List.from(AppConstants.availableModels);
          _selectedModel ??= AppConstants.defaultModel;
        }
        _statusMessage = 'Não foi possível listar modelos do servidor.\n$e';
        _statusOk = false;
      });
    }
  }

  Future<void> _testConnection() async {
    setState(() {
      _testing = true;
      _statusMessage = null;
    });

    final previous = SettingsService.instance.baseUrl;
    await SettingsService.instance.setBaseUrl(_urlController.text);
    final ok = await _api.ping();

    if (!ok) {
      await SettingsService.instance.setBaseUrl(previous);
    }

    if (!mounted) return;

    setState(() {
      _testing = false;
      _statusOk = ok;
      _statusMessage = ok
          ? 'API online. Modelos e chat disponíveis.'
          : 'Falha ao conectar. Verifique a URL e se o backend está no ar.';
    });

    if (ok) await _loadModels();
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
    await SettingsService.instance.setBaseUrl(_urlController.text);
    await SettingsService.instance.setMode(_mode);
    if (_selectedModel != null && _selectedModel!.isNotEmpty) {
      await SettingsService.instance.setModel(_selectedModel!);
    }
    await SettingsService.instance.setTtsAuto(_ttsAuto);
    await SettingsService.instance.setThemeMode(_themeMode);
    await SettingsService.instance.setFontScale(_fontScale);
    await SettingsService.instance.setDeveloperMode(_developerMode);

    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Configurações salvas')));
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.gama.background,
      appBar: AppBar(
        backgroundColor: context.gama.surface,
        title: const Text('Configurações'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
        children: [
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
                  ? SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: context.gama.accent,
                      ),
                    )
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
          const _SectionTitle('Modo de uso'),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _ModeChip(
                  label: 'Programar',
                  icon: Icons.code_rounded,
                  selected: _mode == GamaMode.programar,
                  onTap: () => setState(() => _mode = GamaMode.programar),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _ModeChip(
                  label: 'Conversar',
                  icon: Icons.chat_bubble_outline_rounded,
                  selected: _mode == GamaMode.conversar,
                  onTap: () => setState(() => _mode = GamaMode.conversar),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            _mode == GamaMode.programar
                ? 'Otimizado para código, debug e análise de projetos.'
                : 'Otimizado para diálogo rápido e respostas faláveis (voz).',
            style: TextStyle(
              color: context.gama.textMuted,
              fontSize: 12,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 28),
          Row(
            children: [
              const Expanded(child: _SectionTitle('Modelo')),
              if (_loadingModels)
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: context.gama.accent,
                  ),
                )
              else
                IconButton(
                  tooltip: 'Atualizar lista do servidor',
                  onPressed: _loadModels,
                  icon: Icon(
                    Icons.refresh_rounded,
                    size: 20,
                    color: context.gama.textMuted,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: context.gama.surfaceInput,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: context.gama.border),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                isExpanded: true,
                value: _models.contains(_selectedModel) ? _selectedModel : null,
                hint: Text(
                  _loadingModels
                      ? 'Carregando modelos…'
                      : (_models.isEmpty
                            ? 'Nenhum modelo disponível'
                            : 'Selecione um modelo'),
                  style: TextStyle(color: context.gama.textMuted),
                ),
                dropdownColor: context.gama.surfaceCard,
                style: TextStyle(color: context.gama.textPrimary, fontSize: 15),
                items: _models
                    .map(
                      (model) => DropdownMenuItem(
                        value: model,
                        child: Text(AppConstants.labelFor(model)),
                      ),
                    )
                    .toList(),
                onChanged: _models.isEmpty
                    ? null
                    : (value) {
                        setState(() => _selectedModel = value);
                      },
              ),
            ),
          ),
          if (_models.isEmpty && !_loadingModels)
            Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                'Nenhum modelo retornado pelo backend. Teste a conexão ou '
                'verifique OPENROUTER_MODELS / OLLAMA_MODELS no servidor.',
                style: TextStyle(color: context.gama.textMuted, fontSize: 12),
              ),
            )
          else if (_selectedModel != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'ID: $_selectedModel',
                style: TextStyle(color: context.gama.textHint, fontSize: 12),
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
          const SizedBox(height: 8),
          DropdownButtonFormField<ThemeMode>(
            value: _themeMode,
            decoration: const InputDecoration(
              labelText: 'Tema do aplicativo',
              helperText: 'Escolha o tema escuro, claro ou o tema do sistema.',
            ),
            items: const [
              DropdownMenuItem(value: ThemeMode.dark, child: Text('Escuro')),
              DropdownMenuItem(value: ThemeMode.light, child: Text('Claro')),
              DropdownMenuItem(
                value: ThemeMode.system,
                child: Text('Seguir sistema'),
              ),
            ],
            onChanged: (value) async {
              if (value == null) return;
              setState(() => _themeMode = value);
              await SettingsService.instance.setThemeMode(value);
            },
          ),
          const SizedBox(height: 14),
          DropdownButtonFormField<double>(
            value: _fontScale,
            decoration: const InputDecoration(
              labelText: 'Tamanho do texto',
              helperText: 'Ajusta o texto no aplicativo sem alterar o tamanho do sistema.',
            ),
            items: const [
              DropdownMenuItem(value: 0.9, child: Text('Pequeno · 90%')),
              DropdownMenuItem(value: 1.0, child: Text('Padrão · 100%')),
              DropdownMenuItem(value: 1.1, child: Text('Grande · 110%')),
              DropdownMenuItem(value: 1.2, child: Text('Muito grande · 120%')),
            ],
            onChanged: (value) async {
              if (value == null) return;
              setState(() => _fontScale = value);
              await SettingsService.instance.setFontScale(value);
            },
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
              'Exibe resultados de validação, diagnósticos e custos informados pelo provedor.',
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
                  ? SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: context.gama.error,
                      ),
                    )
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
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _save,
              style: ElevatedButton.styleFrom(
                backgroundColor: context.gama.accent,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 16),
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: const Text(
                'Salvar',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
            ),
          ),
          const SizedBox(height: 20),
          Text(
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

class _ModeChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  const _ModeChip({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? context.gama.accentSoft : context.gama.surfaceCard,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected ? context.gama.accent : context.gama.border,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 18,
                color: selected ? context.gama.accent : context.gama.textMuted,
              ),
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(
                  color: selected
                      ? context.gama.accent
                      : context.gama.textPrimary,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  fontSize: 14,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
