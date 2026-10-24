import 'package:flutter_test/flutter_test.dart';
import 'package:gama/utils/library_filter.dart';

void main() {
  final entries = <Map<String, dynamic>>[
    {'name': 'Correções.zip', 'kind': 'zip', 'bytes': 10},
    {'name': 'Imagem Final.PNG', 'kind': 'image', 'bytes': 20},
    {'name': 'Vídeo.mp4', 'kind': 'video', 'bytes': 30},
    {'name': 'áudio.m4a', 'kind': 'audio', 'bytes': 40},
    {'name': 'sem extensão', 'kind': 'unknown', 'bytes': 0},
  ];

  test('categorias detectam registros legados e extensões', () {
    expect(categoryForLibraryItem(entries[0]), LibraryCategory.documents);
    expect(categoryForLibraryItem(entries[1]), LibraryCategory.images);
    expect(categoryForLibraryItem(entries[2]), LibraryCategory.videos);
    expect(categoryForLibraryItem(entries[3]), LibraryCategory.audio);
    expect(categoryForLibraryItem(entries[4]), LibraryCategory.others);
  });

  test('busca considera acentos e maiúsculas', () {
    expect(filterLibraryItems(entries, query: 'CORRECOES').single['kind'], 'zip');
    expect(filterLibraryItems(entries, query: 'VIDEO').single['kind'], 'video');
  });

  test('filtros combinados não alteram origem', () {
    expect(filterLibraryItems(entries, category: LibraryCategory.documents,
        query: 'imagens'), isEmpty);
    expect(entries.length, 5);
  });
}
