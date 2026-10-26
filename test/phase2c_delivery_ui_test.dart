import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gama/core/gama_colors.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:gama/widgets/generated_files_preview.dart';
import 'package:gama/widgets/message_content.dart';

Widget _app(Widget child, {double width = 360}) => MaterialApp(
  theme: ThemeData(extensions: [GamaPalette.dark()]),
  home: Scaffold(
    body: Center(
      child: SizedBox(
        width: width,
        child: SingleChildScrollView(child: child),
      ),
    ),
  ),
);

void main() {
  testWidgets('Código em largura estreita usa menu sem perder copiar', (tester) async {
    await tester.pumpWidget(_app(const MessageContentView(
      content: '```dart\nvoid main() { print("ok"); }\n```',
      isUser: false,
    ), width: 280));
    expect(find.byTooltip('Mais opções do código'), findsOneWidget);
    expect(find.byTooltip('Copiar código'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('Mais opções do código'));
    await tester.pumpAndSettle();
    expect(find.text('Baixar como arquivo'), findsOneWidget);
    expect(find.text('Abrir código na Oficina'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Código em largura ampla mantém ferramentas diretas', (tester) async {
    await tester.pumpWidget(_app(const MessageContentView(
      content: '```dart\nfinal a = 1;\n```',
      isUser: false,
    ), width: 700));
    expect(find.byTooltip('Mais opções do código'), findsNothing);
    expect(find.byTooltip('Baixar como arquivo'), findsOneWidget);
    expect(find.byTooltip('Copiar código'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Entrega extensa exibe prévia curta e lista completa sob demanda', (tester) async {
    final files = List<Map<String, dynamic>>.generate(35, (i) => {
      'name': 'lib/arquivo_${i + 1}.dart',
      'language': 'dart',
      'size': 256,
    });
    Map<String, dynamic>? selected;
    await tester.pumpWidget(_app(GeneratedFilesPreview(
      files: files,
      onPreview: (file) => selected = file,
    ), width: 380));
    expect(find.text('35 arquivo(s) disponíveis para prévia'), findsOneWidget);
    expect(find.byType(ListTile), findsNWidgets(4));
    await tester.tap(find.text('Ver todos os 35 arquivos'));
    await tester.pumpAndSettle();
    expect(find.text('Arquivos da entrega (35)'), findsOneWidget);
    expect(find.text('lib/arquivo_1.dart'), findsWidgets);
    await tester.tap(find.text('lib/arquivo_1.dart').last);
    await tester.pumpAndSettle();
    expect(selected?['name'], 'lib/arquivo_1.dart');
    expect(find.text('Arquivos da entrega (35)'), findsNothing);
  });

  testWidgets('Mudança de tema atualiza a cor do Markdown já exibido', (tester) async {
    const child = MessageContentView(content: 'Texto da Gamma', isUser: false);
    Widget themed(ThemeData theme) => MaterialApp(
      theme: theme,
      home: const Scaffold(body: child),
    );
    await tester.pumpWidget(themed(ThemeData(
      brightness: Brightness.dark,
      extensions: [GamaPalette.dark()],
    )));
    final dark = tester.widget<MarkdownBody>(find.byType(MarkdownBody).first);
    expect(dark.styleSheet?.p?.color, GamaPalette.dark().textPrimary);
    await tester.pumpWidget(themed(ThemeData(
      brightness: Brightness.light,
      extensions: [GamaPalette.light()],
    )));
    final light = tester.widget<MarkdownBody>(find.byType(MarkdownBody).first);
    expect(light.styleSheet?.p?.color, GamaPalette.light().textPrimary);
  });
}
