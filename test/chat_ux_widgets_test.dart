import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gama/services/settings_service.dart';
import 'package:gama/widgets/chat_composer.dart';
import 'package:gama/widgets/chat_status_indicator.dart';

Widget _testApp(Widget child) => MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(body: Center(child: child)),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ChatComposer', () {
    testWidgets('envia ao tocar no botão de enviar', (tester) async {
      var sendCount = 0;
      final controller = TextEditingController(text: 'Olá, Gama');
      await tester.pumpWidget(_testApp(ChatComposer(
        controller: controller,
        isLoading: false,
        isListening: false,
        mode: GamaMode.conversar,
        onAttach: () {},
        onToggleListen: () {},
        onSend: () => sendCount++,
        onSpeakSend: () {},
        onStop: () {},
        onModeChanged: (_) {},
      )));

      await tester.tap(find.byTooltip('Enviar mensagem'));
      await tester.pump();
      expect(sendCount, 1);
      expect(find.byTooltip('Parar geração'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    });

    testWidgets('mostra parar e interrompe durante a geração', (tester) async {
      var stopCount = 0;
      final controller = TextEditingController();
      await tester.pumpWidget(_testApp(ChatComposer(
        controller: controller,
        isLoading: true,
        isListening: false,
        mode: GamaMode.programar,
        onAttach: () {},
        onToggleListen: () {},
        onSend: () {},
        onSpeakSend: () {},
        onStop: () => stopCount++,
        onModeChanged: (_) {},
      )));

      expect(find.byTooltip('Parar geração'), findsOneWidget);
      await tester.tap(find.byTooltip('Parar geração'));
      await tester.pump();
      expect(stopCount, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    });
  });

  group('ChatStatusIndicator', () {
    testWidgets('mostra estado de trabalho dentro da mensagem', (tester) async {
      await tester.pumpWidget(_testApp(
        const ChatStatusIndicator(label: 'Buscando na web…'),
      ));
      expect(find.text('Buscando na web…'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('mostra erro com ação de tentar novamente', (tester) async {
      var retryCount = 0;
      await tester.pumpWidget(_testApp(ChatStatusIndicator(
        label: 'A resposta não foi concluída.',
        isError: true,
        onRetry: () => retryCount++,
      )));
      expect(find.text('A resposta não foi concluída.'), findsOneWidget);
      await tester.tap(find.text('Tentar novamente'));
      await tester.pump();
      expect(retryCount, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
