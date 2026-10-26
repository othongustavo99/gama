import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
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

  group('ChatComposer: envio no Windows', () {
    setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.windows);
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    testWidgets('Enter chama envio com texto; Shift+Enter nao envia', (tester) async {
      var enviados = 0;
      final controller = TextEditingController();
      final focusNode = FocusNode();
      await tester.pumpWidget(_testApp(ChatComposer(
        controller: controller,
        focusNode: focusNode,
        isLoading: false,
        isListening: false,
        mode: GamaMode.conversar,
        onAttach: () {},
        onToggleListen: () {},
        onSend: () => enviados++,
        onSpeakSend: () {},
        onModeChanged: (_) {},
      )));
      await tester.enterText(find.byType(TextField), 'Teste no Windows');
      await tester.tap(find.byType(TextField));
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      expect(enviados, 0);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(enviados, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      focusNode.dispose();
      controller.dispose();
    });

    testWidgets('botao e Enter numerico acionam o mesmo envio', (tester) async {
      var enviados = 0;
      final controller = TextEditingController(text: 'Oi no Windows');
      final focusNode = FocusNode();
      await tester.pumpWidget(_testApp(ChatComposer(
        controller: controller,
        focusNode: focusNode,
        isLoading: false,
        isListening: false,
        mode: GamaMode.conversar,
        onAttach: () {},
        onToggleListen: () {},
        onSend: () => enviados++,
        onSpeakSend: () {},
        onModeChanged: (_) {},
      )));
      await tester.tap(find.byTooltip('Enviar mensagem'));
      await tester.pump();
      expect(enviados, 1);
      await tester.tap(find.byType(TextField));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.numpadEnter);
      await tester.pump();
      expect(enviados, 2);
      await tester.pumpWidget(const SizedBox.shrink());
      focusNode.dispose();
      controller.dispose();
    });
  });

  group('ChatComposer', () {
    testWidgets('envia ao tocar no botão de enviar', (tester) async {
      var sendCount = 0;
      final controller = TextEditingController(text: 'Olá, Gama');
      await tester.pumpWidget(
        _testApp(
          ChatComposer(
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
          ),
        ),
      );

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
      await tester.pumpWidget(
        _testApp(
          ChatComposer(
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
          ),
        ),
      );

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
      await tester.pumpWidget(
        _testApp(const ChatStatusIndicator(label: 'Buscando na web…')),
      );
      expect(find.text('Buscando na web…'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('mostra erro com ação de tentar novamente', (tester) async {
      var retryCount = 0;
      await tester.pumpWidget(
        _testApp(
          ChatStatusIndicator(
            label: 'A resposta não foi concluída.',
            isError: true,
            onRetry: () => retryCount++,
          ),
        ),
      );
      expect(find.text('A resposta não foi concluída.'), findsOneWidget);
      await tester.tap(find.text('Tentar novamente'));
      await tester.pump();
      expect(retryCount, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
