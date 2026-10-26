import 'package:flutter/material.dart';

import '../core/gama_colors.dart';

/// Prévia enxuta dos arquivos de um artefato. A lista integral só é construída
/// quando o usuário abre o diálogo, evitando centenas de ListTiles no chat.
class GeneratedFilesPreview extends StatelessWidget {
  const GeneratedFilesPreview({
    super.key,
    required this.files,
    required this.onPreview,
    this.visibleCount = 4,
  });

  final List<Map<String, dynamic>> files;
  final ValueChanged<Map<String, dynamic>> onPreview;
  final int visibleCount;

  String _fileName(Map<String, dynamic> file) =>
      file['name']?.toString().trim().isNotEmpty == true
          ? file['name'].toString()
          : 'Arquivo sem nome';

  String _size(dynamic size) {
    final bytes = int.tryParse(size?.toString() ?? '') ?? 0;
    if (bytes <= 0) return 'tamanho não informado';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  Widget _fileTile(BuildContext context, Map<String, dynamic> file,
      {bool closeDialog = false}) {
    final name = _fileName(file);
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: Icon(Icons.description_outlined, size: 20, color: context.gama.accent),
      title: Text(name, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text('${file['language'] ?? 'arquivo'} · ${_size(file['size'])}'),
      trailing: const Icon(Icons.visibility_outlined, size: 19),
      onTap: () {
        if (closeDialog) Navigator.of(context).pop();
        onPreview(file);
      },
      visualDensity: VisualDensity.compact,
    );
  }

  void _showAll(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620, maxHeight: 650),
          child: SizedBox(
            height: MediaQuery.sizeOf(dialogContext).height * 0.70,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 14, 8, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text('Arquivos da entrega (${files.length})',
                          style: Theme.of(dialogContext).textTheme.titleMedium),
                      ),
                      IconButton(
                        tooltip: 'Fechar lista',
                        onPressed: () => Navigator.of(dialogContext).pop(),
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: ListView.builder(
                    itemCount: files.length,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    itemBuilder: (context, index) =>
                        _fileTile(context, files[index], closeDialog: true),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (files.isEmpty) return const SizedBox.shrink();
    final limit = visibleCount < 1 ? 1 : (visibleCount > 12 ? 12 : visibleCount);
    final shown = files.take(limit).toList(growable: false);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('${files.length} arquivo(s) disponíveis para prévia',
          style: TextStyle(color: context.gama.textSecondary, fontSize: 12)),
        for (final file in shown) _fileTile(context, file),
        if (files.length > shown.length)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => _showAll(context),
              icon: const Icon(Icons.list_alt_rounded, size: 18),
              label: Text('Ver todos os ${files.length} arquivos'),
            ),
          ),
      ],
    );
  }
}
