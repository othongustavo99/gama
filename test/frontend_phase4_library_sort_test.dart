import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gama/screens/library_screen.dart';
import 'package:gama/services/local_account_scope.dart';
import 'package:gama/services/settings_service.dart';
import 'package:gama/utils/library_presentation.dart';
import 'package:gama/utils/local_file_metadata.dart';
import 'package:gama/widgets/gama_library_image_tile.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final entries = <Map<String, dynamic>>[
    {'name': 'B.zip', 'at': '2026-11-09T12:00:00', 'bytes': 10, 'kind': 'zip'},
    {'name': 'A.zip', 'at': '2026-11-11T12:00:00', 'bytes': 50, 'kind': 'zip', 'path': '/not/available/a.zip'},
    {'name': 'C.zip', 'at': '2026-11-10T12:00:00', 'bytes': 20, 'kind': 'zip'},
  ];

  test('ordena por data, nome e tamanho sem modificar os registros', () {
    expect(sortLibraryItems(entries).map((e) => e['name']), ['A.zip', 'C.zip', 'B.zip']);
    expect(sortLibraryItems(entries, order: LibrarySortOrder.oldest).map((e) => e['name']),
        ['B.zip', 'C.zip', 'A.zip']);
    expect(sortLibraryItems(entries, order: LibrarySortOrder.name).map((e) => e['name']),
        ['A.zip', 'B.zip', 'C.zip']);
    expect(sortLibraryItems(entries, order: LibrarySortOrder.size).map((e) => e['name']),
        ['A.zip', 'C.zip', 'B.zip']);
    expect(entries.first['name'], 'B.zip');
    expect(sortLibraryItems(entries, order: LibrarySortOrder.size, metadata: {
      '/not/available/a.zip': const LocalFileMetadata(exists: true, bytes: 1),
    }).first['name'], 'C.zip');
  });

  test('registros legados sem data mantêm ordem estável', () {
    final legacy = [
      {'name': 'Imagem'},
      {'name': 'Imagem'},
      {'name': 'Imagem'},
    ];
    final sorted = sortLibraryItems(legacy);
    expect(identical(sorted[0], legacy[0]), isTrue);
    expect(identical(sorted[2], legacy[2]), isTrue);
  });

  testWidgets('cartão indisponível mostra aviso e não tenta abrir/baixar', (tester) async {
    var opens = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: Center(child: SizedBox(
        height: 240,
        width: 240,
        child: GamaLibraryImageTile(
          name: 'imagem-01.png',
          path: '/arquivo-inexistente.png',
          available: false,
          cacheWidth: 300,
          onOpen: () => opens++,
        ),
      ))),
    ));
    expect(find.text('Indisponível neste dispositivo'), findsOneWidget);
    expect(find.text('imagem-01.png'), findsOneWidget);
    await tester.tap(find.text('imagem-01.png'), warnIfMissed: false);
    expect(opens, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Biblioteca organiza e seleciona sem apagar antes de confirmar', (tester) async {
    SharedPreferences.setMockInitialValues({
      LocalAccountScope.current().libraryPrefsKey: jsonEncode(entries),
    });
    await SettingsService.instance.init();
    await tester.pumpWidget(const MaterialApp(home: LibraryScreen()));
    await tester.pumpAndSettle();
    expect(find.text('Biblioteca'), findsOneWidget);
    expect(find.text('Atividades e recuperações'), findsOneWidget);
    await tester.tap(find.byKey(const Key('library-sort-menu')));
    await tester.pumpAndSettle();
    expect(find.text('Nome (A–Z)'), findsWidgets);
    await tester.tap(find.text('Nome (A–Z)').last);
    await tester.pumpAndSettle();
    expect(find.text('A.zip'), findsOneWidget);
    await tester.tap(find.byTooltip('Selecionar arquivos'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('A.zip'));
    await tester.pumpAndSettle();
    expect(find.text('1 selecionado'), findsOneWidget);
    await tester.tap(find.text('Cancelar'));
    await tester.pumpAndSettle();
    expect(find.text('3 arquivos'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('cancelar exclusão múltipla preserva o índice', (tester) async {
    SharedPreferences.setMockInitialValues({
      LocalAccountScope.current().libraryPrefsKey: jsonEncode(entries),
    });
    await SettingsService.instance.init();
    await tester.pumpWidget(const MaterialApp(home: LibraryScreen()));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Selecionar arquivos'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('B.zip'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remover'));
    await tester.pumpAndSettle();
    expect(find.text('Remover 1 arquivo?'), findsOneWidget);
    await tester.tap(find.text('Cancelar').last);
    await tester.pumpAndSettle();
    final prefs = await SharedPreferences.getInstance();
    final stored = jsonDecode(prefs.getString(LocalAccountScope.current().libraryPrefsKey) ?? '[]') as List;
    expect(stored.length, 3);
    expect(stored.first['name'], 'B.zip');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
