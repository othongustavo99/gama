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

  test('Limita a prévia de respostas extremamente longas', () {
    final raw = List.filled(17000, 'A').join();
    final preview = streamingTextPreview(raw, maxCharacters: 3000);
    expect(preview, contains('prévia anterior ocultada'));
    expect(preview.length, lessThan(3100));
    expect(raw.length, 17000);
  });

  testWidgets('Texto em streaming não cria Markdown, imagens ou grandes blocos',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(extensions: [GamaPalette.dark()]),
      home: const Scaffold(
        body: SingleChildScrollView(
          child: MessageContentView(
            content: 'Começando\n\n![foto](https://example.com/abc.jpg)\n\n'
                r'$$E = mc^2$$',
            isUser: false,
            streaming: true,
          ),
        ),
      ),
    ));
    expect(find.byType(Image), findsNothing);
    expect(find.byType(Text), findsWidgets);
    expect(find.textContaining('Começando'), findsOneWidget);
  });
}
