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

  @override
  void initState() {
    super.initState();
    _urlController.text = SettingsService.instance.baseUrl;
    _selectedModel = SettingsService.instance.model;
    _mode = SettingsService.instance.mode;
    _ttsAuto = SettingsService.instance.ttsAuto;
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

      setState(() {
        _models = models;
        // Mantém o modelo atual se ainda estiver na lista; senão pega o primeiro
        if (_selectedModel != null && models.contains(_selectedModel)) {
          // ok
        } else if (models.isNotEmpty) {
          _selectedModel = models.first;
        }
        _loadingModels = false;
      });
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
        backgroundColor: GamaColors.surfaceCard,
        title: const Text(
          'Resetar memória?',
          style: TextStyle(color: GamaColors.textPrimary),
        ),
        content: const Text(
          'Todos os fatos que a Gama guardou sobre você serão apagados. '
          'Essa ação não pode ser desfeita.',
          style: TextStyle(color: GamaColors.textMuted, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: GamaColors.error),
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

    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Configurações salvas')));
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: GamaColors.background,
      appBar: AppBar(
        backgroundColor: GamaColors.surface,
        title: const Text('Configurações'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
        children: [
          const _SectionTitle('API'),
          const SizedBox(height: 10),
          TextField(
            controller: _urlController,
            style: const TextStyle(color: GamaColors.textPrimary, fontSize: 15),
            decoration: InputDecoration(
              hintText: 'https://sua-api.com',
              hintStyle: const TextStyle(color: GamaColors.textHint),
              filled: true,
              fillColor: GamaColors.surfaceInput,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: GamaColors.border),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: GamaColors.border),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(
                  color: GamaColors.accent,
                  width: 1.2,
                ),
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
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: GamaColors.accent,
                      ),
                    )
                  : const Icon(Icons.wifi_tethering_rounded, size: 18),
              label: Text(_testing ? 'Testando…' : 'Testar conexão'),
              style: OutlinedButton.styleFrom(
                foregroundColor: GamaColors.textPrimary,
                side: const BorderSide(color: GamaColors.border),
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
                    ? GamaColors.success.withOpacity(0.12)
                    : GamaColors.error.withOpacity(0.12),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: (_statusOk == true)
                      ? GamaColors.success.withOpacity(0.4)
                      : GamaColors.error.withOpacity(0.4),
                ),
              ),
              child: Text(
                _statusMessage!,
                style: TextStyle(
                  color: (_statusOk == true)
                      ? GamaColors.success
                      : GamaColors.error,
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
            style: const TextStyle(
              color: GamaColors.textMuted,
              fontSize: 12,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 28),
          Row(
            children: [
              const Expanded(child: _SectionTitle('Modelo')),
              if (_loadingModels)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: GamaColors.accent,
                  ),
                )
              else
                IconButton(
                  tooltip: 'Atualizar lista do servidor',
                  onPressed: _loadModels,
                  icon: const Icon(
                    Icons.refresh_rounded,
                    size: 20,
                    color: GamaColors.textMuted,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: GamaColors.surfaceInput,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: GamaColors.border),
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
                  style: const TextStyle(color: GamaColors.textMuted),
                ),
                dropdownColor: GamaColors.surfaceCard,
                style: const TextStyle(
                  color: GamaColors.textPrimary,
                  fontSize: 15,
                ),
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
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                'Nenhum modelo retornado pelo backend. Teste a conexão ou '
                'verifique OPENROUTER_MODELS / OLLAMA_MODELS no servidor.',
                style: TextStyle(color: GamaColors.textMuted, fontSize: 12),
              ),
            )
          else if (_selectedModel != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'ID: $_selectedModel',
                style: const TextStyle(
                  color: GamaColors.textHint,
                  fontSize: 11,
                ),
              ),
            ),
          const SizedBox(height: 28),
          const _SectionTitle('Voz'),
          const SizedBox(height: 6),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text(
              'Ler respostas automaticamente',
              style: TextStyle(color: GamaColors.textPrimary, fontSize: 15),
            ),
            subtitle: const Text(
              'TTS ao finalizar cada resposta do assistente',
              style: TextStyle(color: GamaColors.textMuted, fontSize: 12),
            ),
            value: _ttsAuto,
            activeThumbColor: GamaColors.accent,
            onChanged: (v) => setState(() => _ttsAuto = v),
          ),
          const SizedBox(height: 28),
          const _SectionTitle('Memória'),
          const SizedBox(height: 6),
          const Text(
            'Apaga tudo o que a Gama lembra sobre você (nome, preferências, '
            'projetos…).',
            style: TextStyle(
              color: GamaColors.textMuted,
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
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: GamaColors.error,
                      ),
                    )
                  : const Icon(Icons.delete_sweep_rounded, size: 18),
              label: Text(_resettingMemory ? 'Resetando…' : 'Resetar memória'),
              style: OutlinedButton.styleFrom(
                foregroundColor: GamaColors.error,
                side: BorderSide(color: GamaColors.error.withOpacity(0.5)),
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
                backgroundColor: GamaColors.accent,
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
          const Text(
            'Emulador Android: http://10.0.2.2:8000\n'
            'Celular físico: IP da máquina onde a API está rodando.\n'
            'Release: use sempre HTTPS.',
            style: TextStyle(
              color: GamaColors.textMuted,
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
    return Text(
      text.toUpperCase(),
      style: const TextStyle(
        color: GamaColors.textMuted,
        fontSize: 12,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.6,
      ),
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
      color: selected ? GamaColors.accentSoft : GamaColors.surfaceCard,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected ? GamaColors.accent : GamaColors.border,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 18,
                color: selected ? GamaColors.accent : GamaColors.textMuted,
              ),
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(
                  color: selected ? GamaColors.accent : GamaColors.textPrimary,
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
