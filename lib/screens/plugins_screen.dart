import 'package:flutter/material.dart';

import '../widgets/gama_floating_page.dart';

import '../core/gama_colors.dart';
import '../widgets/loading_skeleton.dart';
import '../services/plugin_settings_service.dart';
import '../utils/error_logger.dart';
import '../utils/friendly_error.dart';

/// Capacidade do sistema (ligada no backend ou local).
class _Plugin {
  final String id;
  final String title;
  final String subtitle;
  final IconData icon;

  const _Plugin({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.icon,
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
    ),
    _Plugin(
      id: 'memory',
      title: 'Memória por usuário',
      subtitle: 'Fatos salvos e sincronizados no servidor',
      icon: Icons.psychology_rounded,
    ),
    _Plugin(
      id: 'tts',
      title: 'Leitura em voz alta',
      subtitle: 'Permite ouvir as respostas no chat',
      icon: Icons.record_voice_over_rounded,
    ),
    _Plugin(
      id: 'scheduled',
      title: 'Agendamentos',
      subtitle: 'Lembretes locais (tela Agendado)',
      icon: Icons.schedule_rounded,
    ),
  ];

  final Map<String, bool> _toggles = {};
  bool _loading = true;
  bool _saving = false;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final map = await PluginSettingsService.instance.load();
      if (!mounted) return;
      setState(() {
        _toggles
          ..clear()
          ..addAll(map);
      });
    } catch (error, stack) {
      logSwallowed(error, stack, context: 'carregar preferências');
      if (mounted) {
        setState(() {
          _loadError = friendlyError(error, acao: 'carregar as preferências');
        });
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _set(String id, bool value) async {
    if (_saving) return;
    final previous = _toggles[id] ?? true;
    setState(() {
      _saving = true;
      _toggles[id] = value;
    });
    try {
      await PluginSettingsService.instance.setEnabled(id, value);
    } catch (error, stack) {
      if (mounted) setState(() => _toggles[id] = previous);
      showFriendlyError(
        mounted ? context : null,
        error,
        stack,
        acao: 'salvar a preferência',
        retry: () => _set(id, value),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.gama.background,

      body: GamaFloatingPage(
        actions: const [],
        contentBehindHeader: true,
        child: _loading
            ? const GamaSkeletonList(itemCount: 4)
            : _loadError != null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_loadError!, textAlign: TextAlign.center),
                      TextButton(
                        onPressed: _load,
                        child: const Text('Tentar de novo'),
                      ),
                    ],
                  ),
                ),
              )
            : ListView.separated(
                padding: EdgeInsets.fromLTRB(
                  16,
                  MediaQuery.paddingOf(context).top + 86,
                  16,
                  16,
                ),
                itemCount: _catalog.length + 1,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (_, i) {
                  if (i == 0) {
                    return Padding(
                      padding: EdgeInsets.only(bottom: 4),
                      child: Text(
                        'Preferências do chat e dos lembretes',
                        style: TextStyle(
                          color: context.gama.textMuted,
                          fontSize: 13,
                          height: 1.4,
                        ),
                      ),
                    );
                  }
                  final p = _catalog[i - 1];
                  final on = _toggles[p.id] ?? true;
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
                          onChanged: _saving ? null : (v) => _set(p.id, v),
                        ),
                      ],
                    ),
                  );
                },
              ),
      ),
    );
  }
}
