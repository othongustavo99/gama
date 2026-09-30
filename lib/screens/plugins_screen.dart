import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/gama_colors.dart';

class PluginsScreen extends StatefulWidget {
  const PluginsScreen({super.key});

  @override
  State<PluginsScreen> createState() => _PluginsScreenState();
}

class _PluginsScreenState extends State<PluginsScreen> {
  bool _memory = true;
  bool _attachments = true;
  bool _autoSummary = true;
  bool _slashCommands = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _memory = prefs.getBool('plugin_memory') ?? true;
      _attachments = prefs.getBool('plugin_attachments') ?? true;
      _autoSummary = prefs.getBool('plugin_auto_summary') ?? true;
      _slashCommands = prefs.getBool('plugin_slash') ?? true;
    });
  }

  Future<void> _set(String key, bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(key, value);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: GamaColors.background,
      appBar: AppBar(
        backgroundColor: GamaColors.surface,
        title: const Text('Plugins'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Recursos da Gamma. Desligar aqui é preferência local '
            '(nem todos os toggles alteram o backend ainda).',
            style: TextStyle(
              color: GamaColors.textMuted,
              fontSize: 13,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 16),
          _tile(
            title: 'Memória de longo prazo',
            subtitle: 'Grava fatos e injeta no system prompt',
            value: _memory,
            onChanged: (v) {
              setState(() => _memory = v);
              _set('plugin_memory', v);
            },
          ),
          _tile(
            title: 'Anexos (código, ZIP, PDF…)',
            subtitle: 'Clipe no chat e extração de conteúdo',
            value: _attachments,
            onChanged: (v) {
              setState(() => _attachments = v);
              _set('plugin_attachments', v);
            },
          ),
          _tile(
            title: 'Resumo automático de contexto',
            subtitle: 'Conversas longas resumidas pelo modelo',
            value: _autoSummary,
            onChanged: (v) {
              setState(() => _autoSummary = v);
              _set('plugin_auto_summary', v);
            },
          ),
          _tile(
            title: 'Comandos /memoria',
            subtitle: 'Atalhos no chat',
            value: _slashCommands,
            onChanged: (v) {
              setState(() => _slashCommands = v);
              _set('plugin_slash', v);
            },
          ),
        ],
      ),
    );
  }

  Widget _tile({
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: GamaColors.surfaceCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: GamaColors.border),
      ),
      child: SwitchListTile(
        title: Text(
          title,
          style: const TextStyle(color: GamaColors.textPrimary),
        ),
        subtitle: Text(
          subtitle,
          style: const TextStyle(color: GamaColors.textMuted, fontSize: 12),
        ),
        value: value,
        activeTrackColor: GamaColors.accent,
        onChanged: onChanged,
      ),
    );
  }
}
