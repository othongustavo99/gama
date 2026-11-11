import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gama/core/gama_colors.dart';
import 'package:gama/core/gama_text_scaler.dart';
import 'package:gama/core/responsive_layout.dart';
import 'package:gama/screens/voice_mode_screen.dart';
import 'package:gama/widgets/gama_section_intro.dart';
import 'package:gama/widgets/loading_skeleton.dart';

class _NonlinearSystemTextScaler extends TextScaler {
  const _NonlinearSystemTextScaler();

  @override
  double scale(double fontSize) => fontSize <= 18 ? fontSize * 1.8 : fontSize * 1.45;

  @override
  double get textScaleFactor => 1.8;
}

void main() {
  test('combina a preferência com a curva nativa do Android', () {
    const system = _NonlinearSystemTextScaler();
    final scaled = gamaEffectiveTextScaler(system, 1.25);
    // 12 * 1.25 = 15 -> curva de fontes pequenas: * 1.8.
    expect(scaled.scale(12), closeTo(27, 0.001));
    // 22 * 1.25 = 27.5 -> curva de fontes grandes: * 1.45.
    expect(scaled.scale(22), closeTo(39.875, 0.001));
    expect(identical(gamaEffectiveTextScaler(system, 1), system), isTrue);
    expect(scaled, GamaUserTextScaler(system, 1.25));
  });

  test('grade respeita largura útil e fontes grandes', () {
    expect(GamaGalleryLayout.columns(260), 1);
    expect(GamaGalleryLayout.columns(380), 2);
    expect(GamaGalleryLayout.columns(380, textScale: 2), 1);
    expect(GamaGalleryLayout.columns(1100), 6);
  });

  test('contraste de textos e ícones importantes é no mínimo 4,5:1', () {
    double ratio(Color a, Color b) {
      final l1 = a.computeLuminance();
      final l2 = b.computeLuminance();
      final lighter = l1 > l2 ? l1 : l2;
      final darker = l1 < l2 ? l1 : l2;
      return (lighter + 0.05) / (darker + 0.05);
    }
    for (final palette in [GamaPalette.dark(), GamaPalette.light()]) {
      expect(ratio(palette.accent, palette.onAccent), greaterThanOrEqualTo(4.5));
      expect(ratio(palette.surfaceInput, palette.textHint), greaterThanOrEqualTo(4.5));
    }
  });

  testWidgets('títulos e skeleton respeitam movimento reduzido', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (context) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          disableAnimations: true,
          textScaler: const TextScaler.linear(2),
        ),
        child: const Scaffold(
          body: Column(children: [
            GamaSectionIntro(
              title: 'Galeria',
              description: 'Imagens criadas e recebidas no aplicativo.',
              icon: Icons.collections_outlined,
            ),
            GamaSkeleton(width: 160),
          ]),
        ),
      )),
    ));
    expect(find.text('Galeria'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('voz suporta tela estreita, texto ampliado e transcrição completa',
      (tester) async {
    tester.view.physicalSize = const Size(320, 520);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final transcript = 'Uma transcrição mais longa, mantida integralmente, '
        'para permitir selecionar, copiar e consultar o conteúdo da conversa '
        'sem precisar sair da tela de voz e sem perder a informação produzida.';
    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          disableAnimations: true,
          textScaler: const TextScaler.linear(2),
        ),
        child: child!,
      ),
      home: VoiceModeScreen(
        isListening: () => true,
        isSpeaking: () => false,
        isProcessing: () => false,
        soundLevel: () => 0,
        transcript: () => transcript,
        onToggleMic: () async {},
        onInterrupt: () async {},
      ),
    ));
    expect(find.text('Estou ouvindo'), findsOneWidget);
    expect(find.text('Ler transcrição completa'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('Ler transcrição completa'));
    await tester.tap(find.text('Ler transcrição completa'));
    await tester.pump();
    expect(find.text('Recolher transcrição'), findsOneWidget);
    expect(find.byType(SelectableText), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
