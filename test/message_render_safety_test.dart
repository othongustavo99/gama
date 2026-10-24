import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gama/core/gama_colors.dart';
import 'package:gama/widgets/message_content.dart';

Widget _testApp(Widget child) => MaterialApp(
  theme: ThemeData(extensions: [GamaPalette.dark()]),
  home: Scaffold(
    body: SingleChildScrollView(child: child),
  ),
);

void main() {
  testWidgets('Imagem Markdown fica compacta durante streaming', (tester) async {
    await tester.pumpWidget(_testApp(const MessageContentView(
      content: 'Criando uma prévia\n\n![Resultado](https://example.com/render.png)',
      isUser: false,
      streaming: true,
    )));
    expect(find.textContaining('Criando uma prévia'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('Link data: não cria imagem em memória pelo Markdown', (tester) async {
    await tester.pumpWidget(_testApp(const MessageContentView(
      content: '![Imagem](data:image/png;base64,AAAA)',
      isUser: false,
    )));
    expect(find.textContaining('Prévia não disponível'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('Imagem acrescentada ao histórico atualiza o cache', (tester) async {
    const tinyPng =
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/pJsAAAAASUVORK5CYII=';
    final image = GeneratedImageData(mime: 'image/png', base64: tinyPng);
    await tester.pumpWidget(_testApp(const MemoizedMessageContentView(
      content: 'Resposta pronta',
      isUser: false,
    )));
    expect(find.byIcon(Icons.download_rounded), findsNothing);

    await tester.pumpWidget(_testApp(MemoizedMessageContentView(
      content: 'Resposta pronta',
      isUser: false,
      additionalImages: [image],
    )));
    await tester.pump();
    expect(find.byIcon(Icons.download_rounded), findsOneWidget);
  });
}
