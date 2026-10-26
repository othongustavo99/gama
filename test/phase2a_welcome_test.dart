import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gama/core/welcome_policy.dart';
import 'package:gama/widgets/welcome_experience.dart';

void main() {
  test('apresentação é isolada por conta e não interrompe usuários antigos', () {
    expect(GamaWelcomePolicy.preferenceKey('google_abc'),
        isNot(GamaWelcomePolicy.preferenceKey('google_xyz')));
    expect(GamaWelcomePolicy.shouldOffer(
      alreadySeen: false, hasConversationHistory: false), isTrue);
    expect(GamaWelcomePolicy.shouldOffer(
      alreadySeen: true, hasConversationHistory: false), isFalse);
    expect(GamaWelcomePolicy.shouldOffer(
      alreadySeen: false, hasConversationHistory: true), isFalse);
  });

  testWidgets('apresentação oferece caminhos úteis e permite dispensar', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: Builder(builder: (context) => ElevatedButton(
        onPressed: () => GamaWelcomeExperience.show(context),
        child: const Text('Conhecer'),
      ))),
    ));
    await tester.tap(find.text('Conhecer'));
    await tester.pumpAndSettle();
    expect(find.text('Bem-vindo à Gamma'), findsOneWidget);
    expect(find.text('Conversar e aprender'), findsOneWidget);
    expect(find.text('Criar na Oficina'), findsOneWidget);
    expect(find.text('Encontrar minhas entregas'), findsOneWidget);
    await tester.tap(find.text('Agora não'));
    await tester.pumpAndSettle();
    expect(find.text('Bem-vindo à Gamma'), findsNothing);
  });
}
