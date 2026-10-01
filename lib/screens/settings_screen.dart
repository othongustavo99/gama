import 'package:flutter/material.dart';

import '../core/constants.dart';
import '../core/gama_colors.dart';
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

  List<String> _models = [];
  String? _selectedModel;
  bool _loadingModels = false;
  bool _testing = false;
  String? _statusMessage;
  bool? _statusOk;

  @override
  void initState() {
    super.initState();
    _urlController.text = SettingsService.instance.baseUrl;
    _selectedModel = SettingsService.instance.model;
    _loadModels();
  }

  Future<void> _loadModels() async {
    setState(() {
      _loadingModels = true;
      _statusMessage = null;
    });

    const allowed = AppConstants.availableModels;

    try {
      final remote = await _api.listModels();
      if (!mounted) return;

      final filtered = allowed
          .where(
            (m) => remote.any((r) => r == m || r.endsWith(m) || m.endsWith(r)),
          )
          .toList();
      final models = filtered.isNotEmpty
          ? filtered
          : List<String>.from(allowed);

      setState(() {
        _models = models;
        if (_selectedModel == null || !models.contains(_selectedModel)) {
          _selectedModel = models.contains(AppConstants.defaultModel)
              ? AppConstants.defaultModel
              : models.first;
        }
        _loadingModels = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _models = List<String>.from(allowed);
        if (_selectedModel == null || !_models.contains(_selectedModel)) {
          _selectedModel = AppConstants.defaultModel;
        }
        _loadingModels = false;
        _statusMessage =
            'API não listou modelos. Usando: qwen2.5-coder:14b e phi4-mini.';
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
          ? 'Frequência40 API e Ollama estão online.'
          : 'Falha ao conectar à Frequência40 API ou ao Ollama.';
    });
    if (ok) {
      await _loadModels();
    }
  }

  Future<void> _save() async {
    await SettingsService.instance.setBaseUrl(_urlController.text);
    if (_selectedModel != null && _selectedModel!.isNotEmpty) {
      await SettingsService.instance.setModel(_selectedModel!);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Configurações salvas')));
    Navigator.pop(context);
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: GamaColors.background,
      appBar: AppBar(
        backgroundColor: GamaColors.surface,
        elevation: 0,
        title: const Text(
          'Configurações',
          style: TextStyle(
            color: GamaColors.textPrimary,
            fontWeight: FontWeight.w600,
          ),
        ),
        iconTheme: const IconThemeData(color: GamaColors.textPrimary),
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(height: 1, color: GamaColors.divider),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const _SectionTitle('Frequência40'),
          const SizedBox(height: 12),
          TextField(
            controller: _urlController,
            style: const TextStyle(color: GamaColors.textPrimary),
            decoration: const InputDecoration(
              labelText: 'URL da API',
              labelStyle: TextStyle(color: GamaColors.textMuted),
              hintText: 'http://127.0.0.1:8000',
              prefixIcon: Icon(Icons.link, color: GamaColors.textMuted),
            ),
            keyboardType: TextInputType.url,
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
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
                      : const Icon(Icons.wifi_tethering, size: 18),
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
              const SizedBox(width: 10),
              Material(
                color: GamaColors.surfaceCard,
                borderRadius: BorderRadius.circular(12),
                child: IconButton(
                  onPressed: _loadingModels ? null : _loadModels,
                  tooltip: 'Atualizar modelos',
                  icon: _loadingModels
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: GamaColors.accent,
                          ),
                        )
                      : const Icon(
                          Icons.refresh,
                          color: GamaColors.textSecondary,
                        ),
                ),
              ),
            ],
          ),
          if (_statusMessage != null) ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: (_statusOk ?? false)
                    ? const Color(0xFF0F2A1A)
                    : const Color(0xFF2A1010),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: (_statusOk ?? false)
                      ? GamaColors.success.withOpacity(0.35)
                      : GamaColors.error.withOpacity(0.35),
                ),
              ),
              child: Text(
                _statusMessage!,
                style: TextStyle(
                  color: (_statusOk ?? false)
                      ? GamaColors.success
                      : GamaColors.error,
                  fontSize: 13,
                ),
              ),
            ),
          ],
          const SizedBox(height: 28),
          const _SectionTitle('Modelo'),
          const SizedBox(height: 12),
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
                  _selectedModel ?? 'Selecione um modelo',
                  style: const TextStyle(color: GamaColors.textMuted),
                ),
                dropdownColor: GamaColors.surfaceCard,
                style: const TextStyle(
                  color: GamaColors.textPrimary,
                  fontSize: 15,
                ),
                items: _models
                    .map(
                      (model) =>
                          DropdownMenuItem(value: model, child: Text(model)),
                    )
                    .toList(),
                onChanged: (value) {
                  setState(() => _selectedModel = value);
                },
              ),
            ),
          ),
          if (_models.isEmpty && !_loadingModels)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                'Nenhum modelo encontrado. Verifique a conexão e o Ollama.',
                style: TextStyle(color: GamaColors.textMuted, fontSize: 12),
              ),
            ),

          const SizedBox(height: 36),
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
                'Salvar configurações',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
            ),
          ),
          const SizedBox(height: 20),
          const Text(
            'Emulador Android: http://10.0.2.2:8000\n'
            'Windows / localhost: http://127.0.0.1:8000\n'
            'Celular na rede: IP do PC + porta 8000',
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
