import 'package:flutter/material.dart';

import '../core/gama_colors.dart';
import '../screens/library_screen.dart';
import '../services/download_service.dart';
import '../services/video_jobs_service.dart';

/// Histórico dos vídeos gerados e trabalhos recuperáveis no backend.
/// "Verificar" consulta um job EXISTENTE, sem consumir uma nova geração.
class VideoJobsPanel extends StatefulWidget {
  final VoidCallback? onLibraryChanged;
  const VideoJobsPanel({super.key, this.onLibraryChanged});

  @override
  State<VideoJobsPanel> createState() => _VideoJobsPanelState();
}

class _VideoJobsPanelState extends State<VideoJobsPanel> {
  List<Map<String, dynamic>> _jobs = const [];
  String? _error;
  bool _loading = true;
  bool _expanded = true;
  final Set<String> _busy = <String>{};

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final jobs = await VideoJobsService.instance.list();
      if (mounted) setState(() => _jobs = jobs);
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Não consegui consultar as gerações.');
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _updateJob(Map<String, dynamic> job) {
    if (!mounted) return;
    final id = job['job_id']?.toString();
    setState(() {
      _jobs = [
        for (final existing in _jobs)
          if (existing['job_id'] == id) job else existing,
      ];
    });
  }

  Future<void> _resume(String id) async {
    if (_busy.contains(id)) return;
    setState(() => _busy.add(id));
    try {
      _updateJob(await VideoJobsService.instance.resume(id));
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Não foi possível verificar o vídeo. Tente novamente.'),
        ));
      }
    } finally {
      if (mounted) setState(() => _busy.remove(id));
    }
  }

  Future<void> _download(Map<String, dynamic> job) async {
    final id = job['job_id']?.toString() ?? '';
    final artifactId = job['artifact_id']?.toString() ?? '';
    if (artifactId.isEmpty || _busy.contains(id)) return;
    setState(() => _busy.add(id));
    try {
      final filename = job['filename']?.toString() ?? 'gama_video.mp4';
      final path = await DownloadService.instance.downloadArtifact(
        '/artifacts/$artifactId/download',
        filename: filename,
      );
      await LibraryScreen.addEntry(
        name: filename,
        kind: 'video',
        bytes: 0,
        sourcePath: path,
        conversationId: job['conversation_id']?.toString(),
      );
      widget.onLibraryChanged?.call();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Vídeo salvo nos downloads e na Biblioteca.'),
        ));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Não consegui baixar o vídeo recuperado.'),
        ));
      }
    } finally {
      if (mounted) setState(() => _busy.remove(id));
    }
  }

  String _status(String raw) => switch (raw) {
    'completed' => 'Concluído',
    'failed' => 'Falhou no provedor',
    'recoverable' => 'Aguardando verificação',
    'processing' => 'Processando no provedor',
    'submitting' => 'Enviando pedido',
    _ => 'Aguardando',
  };

  Widget _jobTile(Map<String, dynamic> job) {
    final g = context.gama;
    final id = job['job_id']?.toString() ?? '';
    final status = job['status']?.toString() ?? '';
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: g.surfaceCard,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: [
              Icon(Icons.movie_creation_outlined, color: g.accent),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _status(status),
                      style: TextStyle(
                        color: g.textPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      job['filename']?.toString() ?? 'Vídeo gerado',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: g.textMuted, fontSize: 11),
                    ),
                  ],
                ),
              ),
              if (_busy.contains(id))
                const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else if (status == 'completed')
                TextButton.icon(
                  onPressed: () => _download(job),
                  icon: const Icon(Icons.download_rounded, size: 16),
                  label: const Text('Baixar'),
                )
              else if (status != 'failed')
                TextButton(
                  onPressed: () => _resume(id),
                  child: const Text('Verificar'),
                ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final g = context.gama;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Gerações de vídeo',
                  style: TextStyle(
                    color: g.textPrimary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (_jobs.isNotEmpty)
                IconButton(
                  tooltip: _expanded ? 'Recolher trabalhos' : 'Mostrar trabalhos',
                  onPressed: () => setState(() => _expanded = !_expanded),
                  icon: Icon(_expanded
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded),
                ),
              IconButton(
                tooltip: 'Atualizar gerações',
                onPressed: _loading ? null : _refresh,
                icon: const Icon(Icons.refresh_rounded),
              ),
            ],
          ),
          if (_loading) const LinearProgressIndicator(minHeight: 2),
          if (_error != null)
            Text(_error!, style: TextStyle(color: g.textMuted)),
          if (!_loading && _jobs.isEmpty && _error == null)
            Text(
              'Nenhuma geração pendente ou recuperável.',
              style: TextStyle(fontSize: 12, color: g.textMuted),
            ),
          if (_expanded && _jobs.isNotEmpty)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 272),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: _jobs.length,
                itemBuilder: (_, index) => _jobTile(_jobs[index]),
              ),
            ),
        ],
      ),
    );
  }
}
