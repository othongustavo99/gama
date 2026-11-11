import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gama/core/gama_colors.dart';
import 'package:gama/widgets/message_content.dart';

Widget _testApp(Widget child) => MaterialApp(
  theme: ThemeData(extensions: [GamaPalette.dark()]),
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

void main() {
  testWidgets('imagem indisponível não bloqueia o primeiro frame', (tester) async {
    await tester.pumpWidget(_testApp(const MessageContentView(
      content: 'Resultado final',
      isUser: false,
      additionalImages: [
        GeneratedImageData(
          mime: 'image/png',
          filePath: '/arquivo-inexistente-gama-phase6/ausente.png',
        ),
      ],
    )));
    expect(find.text('Resultado final'), findsOneWidget);
    // A checagem de disco é assíncrona, sem File.existsSync na montagem.
    await tester.pumpAndSettle();
    expect(find.text('[imagem indisponível]'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('trocar o caminho de arquivo reinicia a verificação', (tester) async {
    const missing = GeneratedImageData(
      mime: 'image/png',
      filePath: '/arquivo-inexistente-gama-phase6/primeiro.png',
    );
    const second = GeneratedImageData(
      mime: 'image/png',
      filePath: '/arquivo-inexistente-gama-phase6/segundo.png',
    );
    await tester.pumpWidget(_testApp(const MessageContentView(
      content: '', isUser: false, additionalImages: [missing],
    )));
    await tester.pumpAndSettle();
    await tester.pumpWidget(_testApp(const MessageContentView(
      content: '', isUser: false, additionalImages: [second],
    )));
    await tester.pumpAndSettle();
    expect(find.text('[imagem indisponível]'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
