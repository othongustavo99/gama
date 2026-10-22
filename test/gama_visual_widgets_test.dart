import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gama/screens/voice_mode_screen.dart';
import 'package:gama/widgets/empty_state.dart';
import 'package:gama/widgets/gama_orb.dart';

Widget _app(Widget child) => MaterialApp(
  theme: ThemeData.dark(),
  home: Scaffold(body: child),
);

void main() {
  testWidgets('a aura respeita animações desativadas', (tester) async {
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: _app(const GamaOrb(size: 100)),
      ),
    );
    expect(find.byType(GamaOrb), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('as sugestões desaparecem quando existe texto', (tester) async {
    final draft = TextEditingController();
    await tester.pumpWidget(
      _app(
        EmptyState(
          draft: draft,
          attachmentKinds: const [],
          onSuggestion: (_, __) {},
        ),
      ),
    );
    expect(find.text('Escrever'), findsOneWidget);
    draft.text = 'Olá, Gama';
    await tester.pump();
    expect(find.text('Escrever'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    draft.dispose();
  });

  testWidgets('modo voz mostra transcrição, mudo e encerramento', (
    tester,
  ) async {
    var muted = false;
    await tester.pumpWidget(
      _app(
        VoiceModeScreen(
          isListening: () => !muted,
          isSpeaking: () => false,
          isProcessing: () => false,
          soundLevel: () => 0.5,
          transcript: () => 'Texto ditado',
          onToggleMic: () async {
            muted = !muted;
          },
          onInterrupt: () async {},
        ),
      ),
    );
    expect(find.text('Texto ditado'), findsOneWidget);
    expect(find.text('Silenciar'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.mic_off_rounded));
    await tester.pump(const Duration(milliseconds: 160));
    expect(muted, isTrue);
    expect(find.text('Ativar microfone'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
