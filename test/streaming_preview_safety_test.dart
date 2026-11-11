import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gama/core/gama_colors.dart';
import 'package:gama/utils/streaming_text_preview.dart';
import 'package:gama/widgets/message_content.dart';

void main() {
  test('Compacta grandes áreas vazias somente na prévia', () {
    final raw = 'Texto inicial${List.filled(1000, '\n').join()}Fim';
    final preview = streamingTextPreview(raw);
    expect(preview, contains('Texto inicial'));
    expect(preview, contains('Fim'));
    expect(preview.length, lessThan(50));
    expect(raw.length, greaterThan(1000));
  });

  test('Preserva o começo e o fim de uma prévia longa', () {
    final raw = 'Início ${List.filled(17000, 'A').join()} fim';
    expect(streamingTextPreview(raw), raw);
  });

  testWidgets('Prévia em streaming não carrega imagens', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(extensions: [GamaPalette.dark()]),
        home: const Scaffold(
          body: SingleChildScrollView(
            child: MessageContentView(
              content:
                  'Começando\n\n![foto](https://example.com/abc.jpg)\n\n'
                  r'$$E = mc^2$$',
              isUser: false,
              streaming: true,
            ),
          ),
        ),
      ),
    );
    expect(find.byType(Image), findsNothing);
    expect(find.byType(Text), findsWidgets);
    expect(find.textContaining('Começando'), findsOneWidget);
  });

  testWidgets('Acrescenta o fim sem perder o começo e o código fechado', (
    tester,
  ) async {
    final code = List.generate(1000, (i) => 'print($i);').join('\n');
    final first = 'Início da resposta\n\n```sql\n$code\n```\n\n';
    final theme = ThemeData(extensions: [GamaPalette.dark()]);
    Future<void> show(String content) => tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Scaffold(
          body: SingleChildScrollView(
            child: MessageContentView(
              content: content,
              isUser: false,
              streaming: true,
            ),
          ),
        ),
      ),
    );

    await show(first);
    final copyButton = find.byWidgetPredicate(
      (widget) => widget is IconButton && widget.tooltip == 'Copiar código',
    );
    final closedBlock = tester.widget<IconButton>(copyButton);
    final tail = List.filled(18000, 'x').join();
    await show('$first$tail fim da resposta');

    expect(find.text('Início da resposta', findRichText: true), findsOneWidget);
    expect(find.textContaining('fim da resposta'), findsOneWidget);
    expect(find.textContaining('print(0);'), findsOneWidget);
    expect(find.textContaining('print(999);'), findsOneWidget);
    expect(tester.widget<IconButton>(copyButton), same(closedBlock));
    expect(tester.takeException(), isNull);
  });
}
