import 'package:flutter/material.dart';

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

    try {
      final models = await _api.listModels();

      if (!mounted) return;

      setState(() {
        _models = models;

        if (_selectedModel == null && models.isNotEmpty) {
          _selectedModel = models.first;
        }

        _loadingModels = false;
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _loadingModels = false;

        _statusMessage = 'Não foi possível listar os modelos.\n$e';

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
      backgroundColor: const Color(0xFF0F0F0F),

      appBar: AppBar(
        backgroundColor: const Color(0xFF1A1A1A),

        title: const Text('Configurações'),

        elevation: 0,
      ),

      body: ListView(
        padding: const EdgeInsets.all(20),

        children: [
          const Text(
            'Frequência40',
            style: TextStyle(
              color: Colors.white70,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),

          const SizedBox(height: 12),

          TextField(
            controller: _urlController,

            style: const TextStyle(color: Colors.white),

            decoration: InputDecoration(
              labelText: 'URL da API',

              labelStyle: TextStyle(color: Colors.grey.shade400),

              hintText: 'http://192.168.0.3:8000',

              hintStyle: TextStyle(color: Colors.grey.shade600),

              filled: true,

              fillColor: const Color(0xFF1F1F1F),

              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),

              prefixIcon: const Icon(Icons.link, color: Colors.white54),
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
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.wifi_tethering),

                  label: Text(_testing ? 'Testando...' : 'Testar conexão'),

                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,

                    side: const BorderSide(color: Color(0xFF333333)),

                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),

              const SizedBox(width: 12),

              IconButton(
                onPressed: _loadingModels ? null : _loadModels,

                tooltip: 'Atualizar modelos',

                icon: _loadingModels
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh, color: Colors.white70),
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
                    ? const Color(0xFF14532D)
                    : const Color(0xFF450A0A),

                borderRadius: BorderRadius.circular(10),
              ),

              child: Text(
                _statusMessage!,

                style: const TextStyle(color: Colors.white, fontSize: 13),
              ),
            ),
          ],

          const SizedBox(height: 28),

          const Text(
            'Modelo',
            style: TextStyle(
              color: Colors.white70,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),

          const SizedBox(height: 12),

          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12),

            decoration: BoxDecoration(
              color: const Color(0xFF1F1F1F),

              borderRadius: BorderRadius.circular(12),
            ),

            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                isExpanded: true,

                value: _models.contains(_selectedModel) ? _selectedModel : null,

                hint: Text(
                  _selectedModel ?? 'Selecione um modelo',

                  style: TextStyle(color: Colors.grey.shade400),
                ),

                dropdownColor: const Color(0xFF1F1F1F),

                style: const TextStyle(color: Colors.white, fontSize: 15),

                items: _models
                    .map(
                      (model) =>
                          DropdownMenuItem(value: model, child: Text(model)),
                    )
                    .toList(),

                onChanged: (value) {
                  setState(() {
                    _selectedModel = value;
                  });
                },
              ),
            ),
          ),

          if (_models.isEmpty && !_loadingModels)
            Padding(
              padding: const EdgeInsets.only(top: 8),

              child: Text(
                'Nenhum modelo encontrado. '
                'Verifique a conexão e se o '
                'Ollama possui modelos instalados.',

                style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
              ),
            ),

          const SizedBox(height: 36),

          SizedBox(
            width: double.infinity,

            child: ElevatedButton(
              onPressed: _save,

              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFFF6B00),

                foregroundColor: Colors.white,

                padding: const EdgeInsets.symmetric(vertical: 16),

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

          const SizedBox(height: 16),

          Text(
            'Emulador Android:\n'
            'http://10.0.2.2:8000\n\n'
            'Celular físico:\n'
            'use o IP da máquina onde a '
            'Frequência40 API está rodando.',

            style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
          ),
        ],
      ),
    );
  }
}
