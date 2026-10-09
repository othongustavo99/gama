import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/gama_colors.dart';

/// Capacidade do sistema (ligada no backend ou local).
class _Plugin {
  final String id;
  final String title;
  final String subtitle;
  final IconData icon;
  final bool serverSide; // se true, só informativo (backend decide)
  final bool defaultOn;

  const _Plugin({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.icon,
    this.serverSide = true,
    this.defaultOn = true,
  });
}

class PluginsScreen extends StatefulWidget {
  const PluginsScreen({super.key});

  @override
  State<PluginsScreen> createState() => _PluginsScreenState();
}

class _PluginsScreenState extends State<PluginsScreen> {
  static const _prefsKey = 'gama_plugin_toggles';

  static const _catalog = <_Plugin>[
    _Plugin(
      id: 'web_search',
      title: 'Busca na web',
      subtitle: 'Respostas com fontes quando o tema exige informação atual',
      icon: Icons.travel_explore_rounded,
      serverSide: true,
      defaultOn: true,
    ),
    _Plugin(
      id: 'memory',
      title: 'Memória por usuário',
      subtitle: 'Fatos salvos e sincronizados no servidor',
      icon: Icons.psychology_rounded,
      serverSide: true,
      defaultOn: true,
    ),
    _Plugin(
      id: 'attachments',
      title: 'Anexos',
      subtitle: 'Imagens, PDF, ZIP e código no chat',
      icon: Icons.attach_file_rounded,
      serverSide: true,
      defaultOn: true,
    ),
    _Plugin(
      id: 'vision',
      title: 'Visão',
      subtitle: 'Análise de imagem quando você anexa foto',
      icon: Icons.image_search_rounded,
      serverSide: true,
      defaultOn: true,
    ),
    _Plugin(
      id: 'code_analyzer',
      title: 'Code Analyzer',
      subtitle: 'Indexação seletiva de projetos ZIP / GitHub / PDF',
      icon: Icons.account_tree_rounded,
      serverSide: true,
      defaultOn: true,
    ),
    _Plugin(
      id: 'tts',
      title: 'Voz (TTS)',
      subtitle: 'Leitura das respostas em voz alta',
      icon: Icons.record_voice_over_rounded,
      serverSide: false,
      defaultOn: true,
    ),
    _Plugin(
      id: 'scheduled',
      title: 'Agendamentos',
      subtitle: 'Lembretes locais (tela Agendado)',
      icon: Icons.schedule_rounded,
      serverSide: false,
      defaultOn: true,
    ),
  ];

  final Map<String, bool> _toggles = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_prefsKey) ?? [];
    final map = <String, bool>{};
    for (final p in _catalog) {
      map[p.id] = p.defaultOn;
    }
    for (final entry in raw) {
      final parts = entry.split('=');
      if (parts.length == 2) {
        map[parts[0]] = parts[1] == '1';
      }
    }
    if (!mounted) return;
    setState(() {
      _toggles
        ..clear()
        ..addAll(map);
      _loading = false;
    });
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    final list =
        _toggles.entries.map((e) => '${e.key}=${e.value ? '1' : '0'}').toList();
    await prefs.setStringList(_prefsKey, list);
  }

  Future<void> _set(String id, bool value, {required bool serverSide}) async {
    if (serverSide) {
      // Capacidade do backend: só informativo neste app.
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Este recurso é controlado pelo servidor. '
            'A UI só indica se está disponível.',
          ),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }
    setState(() => _toggles[id] = value);
    await _persist();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: GamaColors.background,
      appBar: AppBar(
        backgroundColor: GamaColors.surface,
        title: const Text('Plugins'),
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: GamaColors.accent),
            )
          : ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: _catalog.length + 1,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (_, i) {
                if (i == 0) {
                  return const Padding(
                    padding: EdgeInsets.only(bottom: 4),
                    child: Text(
                      'Capacidades ativas na Frequência40. '
                      'Itens do servidor são informativos; itens locais '
                      'podem ser ligadas/desligadas neste aparelho.',
                      style: TextStyle(
                        color: GamaColors.textMuted,
                        fontSize: 13,
                        height: 1.4,
                      ),
                    ),
                  );
                }
                final p = _catalog[i - 1];
                final on = _toggles[p.id] ?? p.defaultOn;
                return Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  decoration: BoxDecoration(
                    color: GamaColors.surfaceCard,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: GamaColors.border),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        p.icon,
                        color: on ? GamaColors.accent : GamaColors.textMuted,
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              p.title,
                              style: const TextStyle(
                                color: GamaColors.textPrimary,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              p.subtitle,
                              style: const TextStyle(
                                color: GamaColors.textMuted,
                                fontSize: 12,
                              ),
                            ),
                            if (p.serverSide)
                              const Padding(
                                padding: EdgeInsets.only(top: 4),
                                child: Text(
                                  'Servidor',
                                  style: TextStyle(
                                    color: GamaColors.textHint,
                                    fontSize: 10,
                                    letterSpacing: 0.4,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                      Switch(
                        value: on,
                        activeThumbColor: GamaColors.accent,
                        onChanged: (v) =>
                            _set(p.id, v, serverSide: p.serverSide),
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }
}
