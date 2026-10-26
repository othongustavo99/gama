import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../core/gama_colors.dart';
import '../screens/library_screen.dart';
import '../services/download_service.dart';
import '../services/recovery_service.dart';

/// Visão de leitura do histórico de tarefas e artefatos mantidos no Railway.
/// O polling consulta estados, mas NUNCA repete uma geração paga.
class RecoveryPanel extends StatefulWidget {
  const RecoveryPanel({super.key, this.onLibraryChanged});
  final VoidCallback? onLibraryChanged;

  @override
  State<RecoveryPanel> createState() => _RecoveryPanelState();
}

class _RecoveryPanelState extends State<RecoveryPanel> {
  Timer? _timer;
  List<Map<String, dynamic>> _jobs = const [];
  List<Map<String, dynamic>> _artifacts = const [];
  bool _loading = true;
  bool _expanded = false;
  String? _error;
  final Set<String> _downloading = {};

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 25), (_) {
      if (mounted && !_loading) _refresh(silent: true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh({bool silent = false}) async {
    if (!mounted || _loading && silent) return;
    if (!silent) setState(() => _loading = true);
    try {
      final response = await Future.wait([
        RecoveryService.instance.jobs(),
        RecoveryService.instance.artifacts(),
      ]);
      if (!mounted) return;
      setState(() {
        _jobs = response[0];
        _artifacts = response[1];
        _error = null;
      });
    } catch (_) {
      if (mounted) setState(() => _error = 'Não foi possível consultar as entregas no servidor.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _download(Map<String, dynamic> artifact) async {
    final id = artifact['artifact_id']?.toString() ?? '';
    if (!RegExp(r'^[a-f0-9]{16}$').hasMatch(id) || _downloading.contains(id)) return;
    setState(() => _downloading.add(id));
    try {
      final name = artifact['filename']?.toString() ?? 'arquivo';
      final path = await DownloadService.instance.downloadArtifact(
        '/artifacts/$id/download', filename: name,
      );
      final bytes = await File(path).length();
      if (bytes == 0) throw const FormatException('Arquivo vazio');
      final kind = artifact['kind']?.toString() ?? 'file';
      await LibraryScreen.addEntry(
        name: name, kind: kind, bytes: bytes, sourcePath: path,
      );
      await DownloadService.instance.exportToDownloads(path, filename: name);
      widget.onLibraryChanged?.call();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Arquivo recuperado e salvo na Biblioteca.'),
        ));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Não consegui baixar. O arquivo pode ter expirado.'),
        ));
      }
    } finally {
      if (mounted) setState(() => _downloading.remove(id));
    }
  }

  String _status(String value) => switch (value) {
    'running' => 'Em andamento',
    'completed' => 'Concluída',
    'failed' => 'Falhou',
    'cancelled' => 'Cancelada',
    'interrupted' => 'Interrompida ou sem atualização',
    _ => 'Aguardando',
  };

  @override
  Widget build(BuildContext context) {
    final g = context.gama;
    final jobs = _jobs.take(6).toList();
    final artifacts = _artifacts.take(8).toList();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(child: Text('Tarefas e entregas', style: TextStyle(
              color: g.textPrimary, fontWeight: FontWeight.w700,
            ))),
            IconButton(
              tooltip: _expanded ? 'Recolher' : 'Expandir',
              onPressed: () => setState(() => _expanded = !_expanded),
              icon: Icon(_expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded),
            ),
            IconButton(
              tooltip: 'Atualizar tarefas e arquivos',
              onPressed: _loading ? null : () => _refresh(),
              icon: const Icon(Icons.refresh_rounded),
            ),
          ]),
          if (_loading) const LinearProgressIndicator(minHeight: 2),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                runSpacing: 4,
                children: [
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      _error!,
                      style: TextStyle(color: g.error, fontSize: 12),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: _loading ? null : () => _refresh(),
                    icon: const Icon(Icons.refresh_rounded, size: 16),
                    label: const Text('Tentar novamente'),
                  ),
                ],
              ),
            ),
          if (_expanded) ...[
            if (jobs.isEmpty && artifacts.isEmpty && !_loading)
              Text('Suas tarefas e arquivos gerados aparecerão aqui.',
                  style: TextStyle(color: g.textMuted, fontSize: 12)),
            if (jobs.isNotEmpty) ...[
              Text('Atividade recente', style: TextStyle(color: g.textMuted, fontSize: 12)),
              const SizedBox(height: 3),
              for (final job in jobs) Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(children: [
                  Icon(job['status'] == 'completed'
                      ? Icons.check_circle_outline_rounded
                      : job['status'] == 'running'
                          ? Icons.timelapse_rounded
                          : Icons.info_outline_rounded,
                      color: g.accent, size: 17),
                  const SizedBox(width: 7),
                  Expanded(child: Text(_status(job['status']?.toString() ?? ''),
                      style: TextStyle(color: g.textPrimary, fontSize: 12))),
                  if (job['status'] == 'completed')
                    Text('No histórico', style: TextStyle(color: g.textMuted, fontSize: 11)),
                ]),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 3, bottom: 7),
                child: Text('Respostas concluídas aparecem nas respectivas conversas.',
                    style: TextStyle(color: g.textMuted, fontSize: 11)),
              ),
            ],
            if (artifacts.isNotEmpty) ...[
              Text('Arquivos no servidor', style: TextStyle(color: g.textMuted, fontSize: 12)),
              const SizedBox(height: 4),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 260),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: artifacts.length,
                  itemBuilder: (_, i) {
                    final artifact = artifacts[i];
                    final id = artifact['artifact_id']?.toString() ?? '';
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(children: [
                        Icon(Icons.insert_drive_file_outlined, size: 17, color: g.accent),
                        const SizedBox(width: 7),
                        Expanded(child: Text(
                          artifact['filename']?.toString() ?? 'Arquivo',
                          maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: g.textPrimary, fontSize: 12),
                        )),
                        if (_downloading.contains(id))
                          const SizedBox(width: 17, height: 17,
                              child: CircularProgressIndicator(strokeWidth: 2))
                        else
                          TextButton(
                            onPressed: () => _download(artifact),
                            child: const Text('Recuperar'),
                          ),
                      ]),
                    );
                  },
                ),
              ),
            ],
            Text('Arquivos no servidor são temporários; salve uma cópia no dispositivo.',
                style: TextStyle(color: g.textMuted, fontSize: 11)),
          ],
        ],
      ),
    );
  }
}
