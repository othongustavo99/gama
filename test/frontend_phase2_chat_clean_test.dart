import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gama/core/gama_colors.dart';
import 'package:gama/models/oficina_kind.dart';
import 'package:gama/services/settings_service.dart';
import 'package:gama/widgets/chat_composer.dart';

Widget _testHost(Widget child, {double width = 320, bool light = false}) {
  return MaterialApp(
    theme: ThemeData(
      extensions: [light ? GamaPalette.light() : GamaPalette.dark()],
    ),
    home: Scaffold(
      body: Center(child: SizedBox(width: width, child: child)),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('compositor estreito mostra apenas ações principais', (tester) async {
    final controller = TextEditingController(text: 'Mensagem curta');
    var attachments = 0;
    var dictation = 0;
    var sends = 0;

    await tester.pumpWidget(_testHost(ChatComposer(
      controller: controller,
      isLoading: false,
      isListening: false,
      mode: GamaMode.conversar,
      onAttach: () => attachments++,
      onToggleListen: () => dictation++,
      onOpenVoice: () {},
      onSend: () => sends++,
      onSpeakSend: () {},
      onModeChanged: (_) {},
    ), width: 285));

    expect(find.byTooltip('Anexar arquivo ou imagem'), findsOneWidget);
    expect(find.byTooltip('Ditar mensagem'), findsOneWidget);
    expect(find.byTooltip('Opções de voz'), findsOneWidget);
    expect(find.byTooltip('Enviar mensagem'), findsOneWidget);
    expect(find.text('Enviar e ouvir resposta'), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byTooltip('Anexar arquivo ou imagem'));
    await tester.tap(find.byTooltip('Ditar mensagem'));
    await tester.tap(find.byTooltip('Enviar mensagem'));
    await tester.pump();
    expect(attachments, 1);
    expect(dictation, 1);
    expect(sends, 1);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('menu de voz preserva conversa e envio com áudio', (tester) async {
    final controller = TextEditingController(text: 'Olá');
    var voice = 0;
    var speakSend = 0;

    await tester.pumpWidget(_testHost(ChatComposer(
      controller: controller,
      isLoading: false,
      isListening: false,
      mode: GamaMode.conversar,
      onAttach: () {},
      onToggleListen: () {},
      onOpenVoice: () => voice++,
      onSend: () {},
      onSpeakSend: () => speakSend++,
      onModeChanged: (_) {},
    )));

    await tester.tap(find.byTooltip('Opções de voz'));
    await tester.pumpAndSettle();
    expect(find.text('Abrir conversa por voz'), findsOneWidget);
    expect(find.text('Enviar e ouvir resposta'), findsOneWidget);
    await tester.tap(find.text('Abrir conversa por voz'));
    await tester.pumpAndSettle();
    expect(voice, 1);

    await tester.tap(find.byTooltip('Opções de voz'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Enviar e ouvir resposta'));
    await tester.pumpAndSettle();
    expect(speakSend, 1);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('envio com áudio não é permitido com campo vazio', (tester) async {
    final controller = TextEditingController();
    var speakSend = 0;
    await tester.pumpWidget(_testHost(ChatComposer(
      controller: controller,
      isLoading: false,
      isListening: false,
      mode: GamaMode.conversar,
      onAttach: () {},
      onToggleListen: () {},
      onOpenVoice: () {},
      onSend: () {},
      onSpeakSend: () => speakSend++,
      onModeChanged: (_) {},
    ), light: true));

    await tester.tap(find.byTooltip('Opções de voz'));
    await tester.pumpAndSettle();
    final speakMenu = tester.widget<PopupMenuItem>(
      find.ancestor(
        of: find.text('Enviar e ouvir resposta'),
        matching: find.byType(PopupMenuItem),
      ).first,
    );
    expect(speakMenu.enabled, isFalse);
    expect(speakSend, 0);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('Oficina conserva ajustes e botão de parar', (tester) async {
    final controller = TextEditingController(text: 'Vídeo de teste');
    var stopped = 0;
    await tester.pumpWidget(_testHost(ChatComposer(
      controller: controller,
      isLoading: true,
      isListening: false,
      mode: GamaMode.programar,
      oficinaKind: OficinaKind.video,
      videoDuration: 10,
      videoAspectRatio: '9:16',
      videoResolution: '720p',
      onAttach: () {},
      onToggleListen: () {},
      onSend: () {},
      onSpeakSend: () {},
      onStop: () => stopped++,
      onModeChanged: (_) {},
      onExitOficina: () {},
    )));

    expect(find.text('9:16 · 10s · 720p'), findsOneWidget);
    expect(find.byTooltip('Parar geração'), findsOneWidget);
    await tester.tap(find.byTooltip('Parar geração'));
    await tester.pump();
    expect(stopped, 1);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
}
