import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gama/core/gama_colors.dart';
import 'package:gama/screens/voice_mode_screen.dart';

void main() {
  testWidgets('reconexão informa estado sem dizer que está ouvindo', (
    tester,
  ) async {
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: MaterialApp(
          theme: ThemeData.dark().copyWith(
            extensions: <ThemeExtension<dynamic>>[GamaPalette.dark()],
          ),
          home: VoiceModeScreen(
            isListening: () => false,
            isReconnecting: () => true,
            isSpeaking: () => false,
            isProcessing: () => false,
            soundLevel: () => 0,
            transcript: () => 'Última transcrição',
            onToggleMic: () async {},
            onInterrupt: () async {},
          ),
        ),
      ),
    );
    expect(find.text('Restabelecendo microfone…'), findsOneWidget);
    expect(find.text('Estou ouvindo'), findsNothing);
    expect(find.text('Última transcrição'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
