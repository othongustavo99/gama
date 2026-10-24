/// Filtro puro para a Biblioteca. Mantém compatibilidade com registros antigos
/// do SharedPreferences, independentemente de origem (chat, Oficina, vídeo).
enum LibraryCategory { all, images, videos, documents, audio, others }

extension LibraryCategoryText on LibraryCategory {
  String get label => switch (this) {
    LibraryCategory.all => 'Tudo',
    LibraryCategory.images => 'Imagens',
    LibraryCategory.videos => 'Vídeos',
    LibraryCategory.documents => 'Documentos',
    LibraryCategory.audio => 'Áudios',
    LibraryCategory.others => 'Outros',
  };
}

LibraryCategory categoryForLibraryItem(Map<String, dynamic> item) {
  final kind = (item['kind'] ?? '').toString().toLowerCase();
  final name = (item['name'] ?? '').toString().toLowerCase();
  if (kind == 'image' || kind.startsWith('image/') ||
      RegExp(r'\.(png|jpe?g|webp|gif|bmp)$').hasMatch(name)) {
    return LibraryCategory.images;
  }
  if (kind == 'video' || kind.startsWith('video/') ||
      RegExp(r'\.(mp4|webm|mov|m4v|mkv)$').hasMatch(name)) {
    return LibraryCategory.videos;
  }
  if (kind == 'audio' || kind.startsWith('audio/') ||
      RegExp(r'\.(mp3|m4a|wav|ogg|flac)$').hasMatch(name)) {
    return LibraryCategory.audio;
  }
  if ({'pdf', 'zip', 'code', 'document', 'file', 'text'}.contains(kind) ||
      RegExp(r'\.(pdf|zip|txt|md|dart|py|js|ts|json|docx?|xlsx?|pptx?)$')
          .hasMatch(name)) {
    return LibraryCategory.documents;
  }
  return LibraryCategory.others;
}

String _normalizeLibraryQuery(String value) => value
    .trim()
    .toLowerCase()
    .replaceAll(RegExp(r'[áàâãä]'), 'a')
    .replaceAll(RegExp(r'[éèêë]'), 'e')
    .replaceAll(RegExp(r'[íìîï]'), 'i')
    .replaceAll(RegExp(r'[óòôõö]'), 'o')
    .replaceAll(RegExp(r'[úùûü]'), 'u')
    .replaceAll('ç', 'c');

List<Map<String, dynamic>> filterLibraryItems(
  Iterable<Map<String, dynamic>> items, {
  LibraryCategory category = LibraryCategory.all,
  String query = '',
}) {
  final needle = _normalizeLibraryQuery(query);
  return items.where((item) {
    if (category != LibraryCategory.all &&
        categoryForLibraryItem(item) != category) return false;
    if (needle.isEmpty) return true;
    final searchable = _normalizeLibraryQuery(
      '${item['name'] ?? ''} ${item['kind'] ?? ''}',
    );
    return searchable.contains(needle);
  }).toList(growable: false);
}
