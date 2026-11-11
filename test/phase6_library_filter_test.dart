import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gama/utils/library_filter.dart';
import 'package:gama/screens/library_screen.dart';
import 'package:gama/services/local_account_scope.dart';
import 'package:gama/services/settings_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
    expect(
      filterLibraryItems(entries, query: 'CORRECOES').single['kind'],
      'zip',
    );
    expect(filterLibraryItems(entries, query: 'VIDEO').single['kind'], 'video');
  });

  test('filtros combinados não alteram origem', () {
    expect(
      filterLibraryItems(
        entries,
        category: LibraryCategory.documents,
        query: 'imagens',
      ),
      isEmpty,
    );
    expect(entries.length, 5);
  });
  testWidgets('Filtro Imagens abre a galeria dentro da Biblioteca', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      LocalAccountScope.current().libraryPrefsKey: jsonEncode(entries),
    });
    await SettingsService.instance.init();
    await tester.pumpWidget(const MaterialApp(home: LibraryScreen()));
    await tester.pumpAndSettle();

    final images = find.widgetWithText(FilterChip, 'Imagens');
    expect(images, findsOneWidget);
    await tester.tap(images);
    await tester.pumpAndSettle();
    final gallery = find.byType(GridView);
    expect(gallery, findsOneWidget);
    expect(
      find.descendant(of: gallery, matching: find.text('Imagem Final.PNG')),
      findsOneWidget,
    );
    expect(find.text('Vídeo.mp4'), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
