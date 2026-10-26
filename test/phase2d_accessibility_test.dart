import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gama/core/gama_colors.dart';
import 'package:gama/services/settings_service.dart';
import 'package:gama/widgets/chat_composer.dart';
import 'package:gama/widgets/chat_status_indicator.dart';

Widget _app(Widget child, {double width = 320, double textScale = 1}) {
  return MaterialApp(
    theme: ThemeData(extensions: [GamaPalette.dark()]),
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: width,
          child: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
            child: SingleChildScrollView(child: child),
          ),
        ),
      ),
    ),
  );
}

ChatComposer _composer({
  required TextEditingController controller,
  required VoidCallback onSend,
  required VoidCallback onVoice,
  required VoidCallback onDictation,
  bool loading = false,
  VoidCallback? onStop,
}) => ChatComposer(
  controller: controller,
  mode: GamaMode.conversar,
  isLoading: loading,
  isListening: false,
  onAttach: () {},
  onToggleListen: onDictation,
  onOpenVoice: onVoice,
  onSend: onSend,
  onSpeakSend: () {},
  onModeChanged: (_) {},
  onStop: onStop,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('barra estreita mantém voz e envio acessíveis', (tester) async {
    final controller = TextEditingController(text: 'Mensagem curta');
    var voiceCount = 0;
    var dictationCount = 0;
    var sent = 0;
    await tester.pumpWidget(_app(_composer(
      controller: controller,
      onSend: () => sent++,
      onVoice: () => voiceCount++,
      onDictation: () => dictationCount++,
    ), width: 285));
    expect(find.byTooltip('Abrir conversa por voz'), findsOneWidget);
    expect(find.byTooltip('Ditar mensagem'), findsOneWidget);
    expect(find.byTooltip('Enviar mensagem'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('Abrir conversa por voz'));
    await tester.pump();
    expect(voiceCount, 1);
    await tester.tap(find.byTooltip('Ditar mensagem'));
    await tester.pump();
    expect(dictationCount, 1);
    await tester.tap(find.byTooltip('Enviar mensagem'));
    await tester.pump();
    expect(sent, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('texto ampliado não corta os controles do composer', (tester) async {
    final controller = TextEditingController(text: 'Olá');
    await tester.pumpWidget(_app(_composer(
      controller: controller,
      onSend: () {},
      onVoice: () {},
      onDictation: () {},
    ), width: 350, textScale: 1.5));
    expect(find.byTooltip('Abrir conversa por voz'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('durante geração mostra parada acionável', (tester) async {
    final controller = TextEditingController();
    var stopped = 0;
    await tester.pumpWidget(_app(_composer(
      controller: controller,
      loading: true,
      onSend: () {},
      onVoice: () {},
      onDictation: () {},
      onStop: () => stopped++,
    )));
    await tester.tap(find.byTooltip('Parar geração'));
    await tester.pump();
    expect(stopped, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('estado de erro longo mantém ações na largura pequena', (tester) async {
    var retried = 0;
    await tester.pumpWidget(_app(ChatStatusIndicator(
      label: 'A resposta foi interrompida antes de todos os arquivos '
          'serem entregues; tente novamente.',
      isError: true,
      onRetry: () => retried++,
    ), width: 285));
    expect(find.text('Tentar novamente'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Tentar novamente'));
    await tester.pump();
    expect(retried, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Enter envia e Shift+Enter continua disponível no Windows',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final controller = TextEditingController(text: 'Mensagem no PC');
    final focus = FocusNode();
    var sent = 0;
    await tester.pumpWidget(_app(ChatComposer(
      controller: controller,
      focusNode: focus,
      isLoading: false,
      isListening: false,
      mode: GamaMode.conversar,
      onAttach: () {},
      onToggleListen: () {},
      onSend: () => sent++,
      onSpeakSend: () {},
      onModeChanged: (_) {},
    ), width: 450));
    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(sent, 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(sent, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    focus.dispose();
    controller.dispose();
  });
}
