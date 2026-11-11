import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gama/models/oficina_kind.dart';
import 'package:gama/screens/settings_screen.dart';
import 'package:gama/services/settings_service.dart';
import 'package:gama/widgets/chat_composer.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('Ajustes de vídeo usam seções e atualizam o resumo ao aplicar', (
    tester,
  ) async {
    final controller = TextEditingController();
    var ratio = '16:9';
    var duration = 5;
    var resolution = '480p';
    var audio = true;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => ChatComposer(
              controller: controller,
              isLoading: false,
              isListening: false,
              mode: GamaMode.conversar,
              onAttach: () {},
              onToggleListen: () {},
              onSend: () {},
              onSpeakSend: () {},
              onModeChanged: (_) {},
              oficinaKind: OficinaKind.video,
              videoAspectRatio: ratio,
              videoDuration: duration,
              videoResolution: resolution,
              videoGenerateAudio: audio,
              onVideoAspectRatioChanged: (value) =>
                  setState(() => ratio = value),
              onVideoDurationChanged: (value) =>
                  setState(() => duration = value),
              onVideoResolutionChanged: (value) =>
                  setState(() => resolution = value),
              onVideoGenerateAudioChanged: (value) =>
                  setState(() => audio = value),
            ),
          ),
        ),
      ),
    );

    expect(find.byType(ChoiceChip), findsNothing);
    expect(find.text('16:9 · 5s · 480p'), findsOneWidget);
    await tester.tap(find.text('Ajustes'));
    await tester.pumpAndSettle();

    for (final title in ['Proporção', 'Duração', 'Resolução', 'Áudio']) {
      expect(find.text(title), findsOneWidget);
    }
    await tester.tap(find.text('9:16'));
    await tester.tap(find.text('10s'));
    await tester.tap(find.text('720p'));
    await tester.ensureVisible(find.text('Áudio'));
    await tester.tap(find.text('Áudio'));
    await tester.ensureVisible(find.text('Aplicar ajustes'));
    await tester.tap(find.text('Aplicar ajustes'));
    await tester.pumpAndSettle();

    expect(find.text('9:16 · 10s · 720p'), findsOneWidget);
    expect(audio, isFalse);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('Aparência e Voz abrem páginas próprias e salvam preferências', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await SettingsService.instance.init();
    await tester.pumpWidget(const MaterialApp(home: SettingsScreen()));

    for (final name in ['Aparência', 'Voz', 'Memória', 'Plano', 'Conta']) {
      expect(find.text(name), findsOneWidget);
    }
    expect(find.text('Reduzir animações'), findsNothing);

    await tester.tap(find.text('Aparência'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reduzir animações'));
    await tester.pumpAndSettle();
    expect(SettingsService.instance.reduceMotion, isTrue);

    await tester.tap(find.byTooltip('Voltar'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Voz'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ler respostas automaticamente'));
    await tester.pumpAndSettle();
    expect(SettingsService.instance.ttsAuto, isTrue);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'Composer usa fundo sólido com movimento reduzido ou frames lentos',
    (tester) async {
      final controller = TextEditingController();
      final composer = ChatComposer(
        controller: controller,
        isLoading: false,
        isListening: false,
        mode: GamaMode.conversar,
        onAttach: () {},
        onToggleListen: () {},
        onSend: () {},
        onSpeakSend: () {},
        onModeChanged: (_) {},
      );

      Future<void> show({required bool reduceMotion}) => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(disableAnimations: reduceMotion),
                child: composer,
              ),
            ),
          ),
        ),
      );
      await show(reduceMotion: true);
      expect(find.byType(BackdropFilter), findsNothing);
      await show(reduceMotion: false);
      expect(find.byType(BackdropFilter), findsOneWidget);

      final slowFrame = FrameTiming(
        vsyncStart: 0,
        buildStart: 0,
        buildFinish: 70000,
        rasterStart: 70000,
        rasterFinish: 74000,
        rasterFinishWallTime: 74000,
      );
      tester.binding.platformDispatcher.onReportTimings!(
        List.filled(8, slowFrame),
      );
      await tester.pump();
      expect(find.byType(BackdropFilter), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
    variant: const TargetPlatformVariant({TargetPlatform.android}),
  );
}
