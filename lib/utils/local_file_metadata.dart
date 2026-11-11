import 'dart:io';

/// Resultado de uma consulta de arquivo realizada fora do build dos widgets.
class LocalFileMetadata {
  const LocalFileMetadata({required this.exists, required this.bytes});

  final bool exists;
  final int bytes;

  bool get hasContent => exists && bytes > 0;
}

/// Lê o estado de arquivos locais de forma assíncrona e em lotes limitados.
/// Caminhos repetidos são verificados uma única vez por atualização da lista.
/// Não altera nem remove arquivos; entradas indisponíveis permanecem visíveis.
Future<Map<String, LocalFileMetadata>> loadLocalFileMetadata(
  Iterable<Map<String, dynamic>> entries, {
  int batchSize = 24,
}) async {
  final uniquePaths = entries
      .map((entry) => entry['path']?.toString())
      .whereType<String>()
      .where((path) => path.isNotEmpty)
      .toSet()
      .toList(growable: false);

  final snapshots = <String, LocalFileMetadata>{};
  final limit = batchSize <= 0 ? 24 : batchSize;

  for (var start = 0; start < uniquePaths.length; start += limit) {
    final batch = uniquePaths.skip(start).take(limit);
    final result = await Future.wait(
      batch.map((path) async {
        try {
          final stat = await File(path).stat();
          final exists = stat.type == FileSystemEntityType.file;
          return (
            path,
            LocalFileMetadata(exists: exists, bytes: exists ? stat.size : 0),
          );
        } catch (_) {
          // Caminho inacessível, inexistente ou sem permissão.
          return (path, const LocalFileMetadata(exists: false, bytes: 0));
        }
      }),
    );
    for (final item in result) {
      snapshots[item.$1] = item.$2;
    }
  }
  return snapshots;
}
