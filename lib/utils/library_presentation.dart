import 'local_file_metadata.dart';

/// Ordenações locais: nenhum arquivo é alterado ou movido no disco.
enum LibrarySortOrder { newest, oldest, name, size }

extension LibrarySortOrderLabel on LibrarySortOrder {
  String get label => switch (this) {
    LibrarySortOrder.newest => 'Mais recentes',
    LibrarySortOrder.oldest => 'Mais antigos',
    LibrarySortOrder.name => 'Nome (A–Z)',
    LibrarySortOrder.size => 'Maiores arquivos',
  };
}

/// Não depende de Widgets, SharedPreferences nem serviços remotos.
List<Map<String, dynamic>> sortLibraryItems(
  Iterable<Map<String, dynamic>> items, {
  LibrarySortOrder order = LibrarySortOrder.newest,
  Map<String, LocalFileMetadata> metadata = const {},
}) {
  final indexed = items.toList(growable: false).asMap().entries.toList();
  DateTime dateOf(Map<String, dynamic> item) =>
      DateTime.tryParse(item['at']?.toString() ?? '') ??
      DateTime.fromMillisecondsSinceEpoch(0);
  int sizeOf(Map<String, dynamic> item) {
    final path = item['path']?.toString();
    final snapshot = path == null ? null : metadata[path];
    if (snapshot != null && snapshot.exists) return snapshot.bytes;
    final saved = item['bytes'];
    return saved is num ? saved.toInt() : 0;
  }
  int byName(Map<String, dynamic> a, Map<String, dynamic> b) =>
      (a['name']?.toString() ?? '').toLowerCase().compareTo(
        (b['name']?.toString() ?? '').toLowerCase(),
      );

  indexed.sort((a, b) {
    final result = switch (order) {
      LibrarySortOrder.newest => dateOf(b.value).compareTo(dateOf(a.value)),
      LibrarySortOrder.oldest => dateOf(a.value).compareTo(dateOf(b.value)),
      LibrarySortOrder.name => byName(a.value, b.value),
      LibrarySortOrder.size => sizeOf(b.value).compareTo(sizeOf(a.value)),
    };
    // Ordem estável para registros sem data, com nomes iguais, etc.
    return result != 0 ? result : a.key.compareTo(b.key);
  });
  return indexed.map((entry) => entry.value).toList(growable: false);
}

