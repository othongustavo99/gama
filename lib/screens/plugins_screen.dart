import 'package:flutter/material.dart';

import '../core/gama_colors.dart';
import '../services/plugin_settings_service.dart';

/// Capacidade do sistema (ligada no backend ou local).
class _Plugin {
  final String id;
  final String title;
  final String subtitle;
  final IconData icon;
  final bool
  serverSide; // recurso executado no backend, controlado por requisição
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
    final map = await PluginSettingsService.instance.load();
    for (final p in _catalog) {
      map.putIfAbsent(p.id, () => p.defaultOn);
    }
    if (!mounted) return;
    setState(() {
      _toggles
        ..clear()
        ..addAll(map);
      _loading = false;
    });
  }

  Future<void> _set(String id, bool value, {required bool serverSide}) async {
    final previous = _toggles[id];
    setState(() => _toggles[id] = value);
    try {
      await PluginSettingsService.instance.setEnabled(id, value);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            value
                ? 'Recurso ativado para as próximas mensagens.'
                : 'Recurso desativado para as próximas mensagens.',
          ),
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (_) {
      if (mounted) setState(() => _toggles[id] = previous ?? true);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Não foi possível salvar a configuração.'),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.gama.background,
      appBar: AppBar(
        backgroundColor: context.gama.surface,
        title: const Text('Plugins'),
      ),
      body: _loading
          ? Center(child: CircularProgressIndicator(color: context.gama.accent))
          : ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: _catalog.length + 1,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (_, i) {
                if (i == 0) {
                  return Padding(
                    padding: EdgeInsets.only(bottom: 4),
                    child: Text(
                      'Essas opções controlam os recursos usados nas próximas mensagens. '
                      'As alterações são salvas neste aparelho e enviadas à API quando necessário.',
                      style: TextStyle(
                        color: context.gama.textMuted,
                        fontSize: 13,
                        height: 1.4,
                      ),
                    ),
                  );
                }
                final p = _catalog[i - 1];
                final on = _toggles[p.id] ?? p.defaultOn;
                return Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: context.gama.surfaceCard,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: context.gama.border),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        p.icon,
                        color: on
                            ? context.gama.accent
                            : context.gama.textMuted,
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              p.title,
                              style: TextStyle(
                                color: context.gama.textPrimary,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              p.subtitle,
                              style: TextStyle(
                                color: context.gama.textMuted,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Switch(
                        value: on,
                        activeThumbColor: context.gama.accent,
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
