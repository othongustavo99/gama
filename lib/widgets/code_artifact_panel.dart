import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/gama_colors.dart';
import '../models/code_artifact.dart';
import '../screens/code_diff_screen.dart';
import '../services/code_artifact_service.dart';
import '../services/download_service.dart';
import '../utils/friendly_error.dart';

class CodeArtifactPanel extends StatefulWidget {
  const CodeArtifactPanel({
    super.key,
    required this.snippets,
    required this.archives,
    required this.originals,
    required this.onClose,
    required this.onDownloadArchive,
    this.initialArchiveId,
    this.initialFile,
  });

  final List<CodeArtifactFile> snippets;
  final List<CodeArchive> archives;
  final Map<String, String> originals;
  final VoidCallback onClose;
  final ValueChanged<CodeArchive> onDownloadArchive;
  final String? initialArchiveId;
  final String? initialFile;

  @override
  State<CodeArtifactPanel> createState() => _CodeArtifactPanelState();
}

typedef _Preview = ({String? text, String? reason, String? diff});

class _CodeArtifactPanelState extends State<CodeArtifactPanel> {
  final _service = CodeArtifactService();
  final _indexes = <String, Future<List<CodeArtifactFile>>>{};
  final _previews = <(String, int), Future<_Preview>>{};
  late int _source = _initialSource();
  int? _selectedFile;
  bool _showDiff = false;
  bool _saving = false;

  int _initialSource() {
    if (widget.archives.isEmpty) return -1;
    final index = widget.archives.indexWhere(
      (item) => item.id == widget.initialArchiveId,
    );
    return index >= 0 ? index : 0;
  }

  @override
  void dispose() {
    _service.dispose();
    super.dispose();
  }

  Future<void> _run(
    String action,
    Future<void> Function() operation,
    String success,
  ) async {
    try {
      await operation();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(success)));
      }
    } catch (error, stack) {
      showFriendlyError(mounted ? context : null, error, stack, acao: action);
    }
  }

  Future<void> _download(CodeArchive? archive, CodeArtifactFile file) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await _run('baixar o arquivo', () async {
        if (archive != null) {
          await _service.download(archive, file);
        } else {
          await DownloadService.instance.saveText(
            file.content!,
            filename: file.name,
          );
        }
      }, 'Arquivo salvo');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.gama;
    final archive = _source < 0 ? null : widget.archives[_source];
    return Material(
      color: palette.surface,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 16, right: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Artefatos',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  if (archive != null)
                    IconButton(
                      tooltip: 'Baixar ZIP',
                      onPressed: () => widget.onDownloadArchive(archive),
                      icon: const Icon(Icons.folder_zip_outlined),
                    ),
                  IconButton(
                    tooltip: 'Fechar artefatos',
                    onPressed: widget.onClose,
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            if (widget.archives.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: DropdownButton<int>(
                  isExpanded: true,
                  value: _source,
                  items: [
                    if (widget.snippets.isNotEmpty)
                      const DropdownMenuItem(
                        value: -1,
                        child: Text('Código da resposta'),
                      ),
                    for (final (index, item) in widget.archives.indexed)
                      DropdownMenuItem(
                        value: index,
                        child: Text(item.name, overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged: (value) {
                    if (value == null || value == _source) return;
                    setState(() {
                      _source = value;
                      _selectedFile = 0;
                      _showDiff = false;
                    });
                  },
                ),
              ),
            const Divider(height: 1),
            Expanded(
              child: archive == null
                  ? _files(widget.snippets, null)
                  : FutureBuilder<List<CodeArtifactFile>>(
                      key: ValueKey(archive.id),
                      future: _indexes.putIfAbsent(
                        archive.id,
                        () => _service.listFiles(archive),
                      ),
                      builder: (context, snapshot) {
                        if (snapshot.connectionState != ConnectionState.done) {
                          return const Center(
                            child: CircularProgressIndicator(),
                          );
                        }
                        if (snapshot.hasError) {
                          return _retry(
                            'Não foi possível abrir a lista do ZIP.',
                            () => setState(() => _indexes.remove(archive.id)),
                          );
                        }
                        return _files(snapshot.data ?? [], archive);
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _retry(String message, VoidCallback retry) => Center(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(message, textAlign: TextAlign.center),
          TextButton(onPressed: retry, child: const Text('Tentar de novo')),
        ],
      ),
    ),
  );

  Widget _files(List<CodeArtifactFile> files, CodeArchive? archive) {
    if (files.isEmpty)
      return const Center(child: Text('Nenhum arquivo disponível.'));
    final requested = files.indexWhere(
      (file) => file.name == widget.initialFile,
    );
    final index = _selectedFile ?? (requested < 0 ? 0 : requested);
    final file = files[index];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 48,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            itemCount: files.length,
            separatorBuilder: (_, _) => const SizedBox(width: 6),
            itemBuilder: (context, i) => Center(
              child: ChoiceChip(
                label: Text(files[i].name),
                selected: i == index,
                onSelected: (_) => setState(() {
                  _selectedFile = i;
                  _showDiff = false;
                }),
              ),
            ),
          ),
        ),
        Expanded(
          child: archive == null
              ? _fileView(file, null, (
                  text: file.content,
                  reason: null,
                  diff: null,
                ))
              : _archivePreview(archive, file),
        ),
      ],
    );
  }

  Widget _archivePreview(CodeArchive archive, CodeArtifactFile file) {
    final key = (archive.id, file.archiveIndex!);
    return FutureBuilder<_Preview>(
      key: ValueKey(key),
      future: _previews.putIfAbsent(key, () => _service.preview(archive, file)),
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return _retry(
            'Não foi possível carregar a prévia.',
            () => setState(() => _previews.remove(key)),
          );
        }
        return _fileView(file, archive, snapshot.data!);
      },
    );
  }

  Widget _fileView(
    CodeArtifactFile file,
    CodeArchive? archive,
    _Preview preview,
  ) {
    final text = preview.text;
    final original = widget.originals[file.name];
    final zipDiff = preview.diff;
    final canCompare = original != null && text != null;
    final canDiff = zipDiff != null || canCompare;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  file.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (canDiff)
                IconButton(
                  tooltip: _showDiff ? 'Ver código' : 'Comparar alterações',
                  isSelected: _showDiff,
                  onPressed: () => setState(() => _showDiff = !_showDiff),
                  icon: const Icon(Icons.difference_outlined),
                ),
              IconButton(
                tooltip: 'Copiar código',
                onPressed: text == null
                    ? null
                    : () => _run(
                        'copiar o código',
                        () => Clipboard.setData(ClipboardData(text: text)),
                        'Código copiado',
                      ),
                icon: const Icon(Icons.copy_rounded),
              ),
              IconButton(
                tooltip: 'Baixar arquivo',
                onPressed: _saving ? null : () => _download(archive, file),
                icon: const Icon(Icons.download_outlined),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: _showDiff && zipDiff != null
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Padding(
                      padding: EdgeInsets.all(12),
                      child: Text('Prévia das alterações do ZIP'),
                    ),
                    Expanded(child: UnifiedCodeDiffView(content: zipDiff)),
                  ],
                )
              : _showDiff && canCompare
              ? CodeDiffView(
                  original: original,
                  proposed: text,
                  language: file.language,
                )
              : text == null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      preview.reason == 'too_large'
                          ? 'Arquivo grande para exibir aqui. Baixe a versão completa.'
                          : 'Prévia de texto indisponível. Baixe o arquivo para abrir.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : _CodeText(text: text),
        ),
      ],
    );
  }
}

class _CodeText extends StatefulWidget {
  const _CodeText({required this.text});

  final String text;

  @override
  State<_CodeText> createState() => _CodeTextState();
}

class _CodeTextState extends State<_CodeText> {
  late List<String> _lines = widget.text.split('\n');

  @override
  void didUpdateWidget(covariant _CodeText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) _lines = widget.text.split('\n');
  }

  @override
  Widget build(BuildContext context) => SelectionArea(
    child: ListView.builder(
      key: ValueKey(widget.text.hashCode),
      padding: const EdgeInsets.all(16),
      itemCount: (_lines.length + 39) ~/ 40,
      itemBuilder: (context, index) => Text(
        _lines
            .getRange(index * 40, ((index + 1) * 40).clamp(0, _lines.length))
            .join('\n'),
        style: const TextStyle(
          fontFamily: 'monospace',
          fontSize: 13,
          height: 1.5,
        ),
      ),
    ),
  );
}
