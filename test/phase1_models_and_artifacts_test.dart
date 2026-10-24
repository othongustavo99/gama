import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gama/core/constants.dart';
import 'package:gama/models/message.dart';
import 'package:gama/services/settings_service.dart';
import 'package:gama/widgets/chat_composer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Conversar usa GPT e Trabalhar usa GLM', () {
    expect(SettingsService.modelForMode(GamaMode.conversar),
        AppConstants.modelConversar);
    expect(SettingsService.modelForMode(GamaMode.programar),
        AppConstants.modelProgramar);
    expect(AppConstants.modelConversar, 'openai/gpt-5.4-mini');
    expect(AppConstants.modelProgramar, 'z-ai/glm-5.3-flash');
  });

  test('Metadados de artefatos podem ser salvos e restaurados sem arquivo binário', () {
    final message = Message(id: 'm1', role: 'assistant',
        content: 'Arquivo gerado', conversationId: 'c1');
    message.artifacts = [
      {'artifact_id': 'zip_123456', 'kind': 'zip', 'filename': 'correcao.zip'}
    ];
    final restored = Message(id: message.id, role: message.role,
        content: message.content, conversationId: message.conversationId,
        artifactsJson: message.artifactsJson);
    expect(restored.artifacts.single['filename'], 'correcao.zip');
    expect(Message(id: 'antiga', role: 'assistant',
        content: 'Oi', conversationId: 'c1').artifacts, isEmpty);
  });

  testWidgets('Composer envia só anexo, sem exigir texto', (tester) async {
    var sends = 0;
    final controller = TextEditingController();
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(body: ChatComposer(
        controller: controller,
        isLoading: false,
        isListening: false,
        mode: GamaMode.conversar,
        hasAttachments: true,
        onAttach: () {},
        onToggleListen: () {},
        onSend: () => sends++,
        onSpeakSend: () {},
        onModeChanged: (_) {},
      )),
    ));
    await tester.tap(find.byTooltip('Enviar mensagem'));
    await tester.pump();
    expect(sends, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('Composer bloqueia envio enquanto indexa anexo', (tester) async {
    var sends = 0;
    final controller = TextEditingController();
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(body: ChatComposer(
        controller: controller,
        isLoading: false,
        isListening: false,
        mode: GamaMode.conversar,
        hasAttachments: true,
        attachmentsReady: false,
        onAttach: () {},
        onToggleListen: () {},
        onSend: () => sends++,
        onSpeakSend: () {},
        onModeChanged: (_) {},
      )),
    ));
    await tester.tap(find.byTooltip('Enviar mensagem'));
    await tester.pump();
    expect(sends, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
}
