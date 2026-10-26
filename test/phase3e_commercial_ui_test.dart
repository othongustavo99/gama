import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gama/core/gama_colors.dart';
import 'package:gama/models/commercial_account.dart';
import 'package:gama/screens/commercial_screen.dart';
import 'package:gama/services/commercial_service.dart';
import 'package:gama/utils/commercial_limit_message.dart';
import 'package:gama/widgets/chat_status_indicator.dart';

Map<String, dynamic> _payload({bool enforced = false}) => {
  'plan': 'pro',
  'plan_expires_at': '2026-11-15T12:00:00+00:00',
  'credits_balance': 20,
  'limits': {'chat': 150, 'image': 10, 'video': 2, 'artifact': 20},
  'usage_today': {'chat': 19, 'image': 3, 'video': 0, 'artifact': 1},
  'day_utc': '2026-10-26',
  'enforcement_active': enforced,
  'payments_active': false,
  'limits_preview_only': !enforced,
};

Widget _app(Widget body, {double width = 390}) => MaterialApp(
  theme: ThemeData(extensions: [GamaPalette.dark()]),
  home: MediaQuery(
    data: const MediaQueryData().copyWith(size: Size(width, 780)),
    child: SizedBox(width: width, child: body),
  ),
);

void main() {
  test('converte o snapshot real do backend sem criar saldos inexistentes', () {
    final preview = CommercialAccount.fromJson(_payload());
    expect(preview.displayPlan, 'Pro');
    expect(preview.used('chat'), 19);
    expect(preview.limit('image'), 10);
    expect(preview.remaining('chat'), isNull);
    expect(preview.creditsBalance, 20);
    expect(preview.paymentsActive, false);
    final applied = CommercialAccount.fromJson(_payload(enforced: true));
    expect(applied.remaining('chat'), 131);
    expect(applied.remaining('video'), 2);
    expect(() => CommercialAccount.fromJson({..._payload(), 'credits_balance': -2}),
      throwsFormatException);
    expect(() => CommercialAccount.fromJson({..._payload(), 'limits': {'chat': -1}}),
      throwsFormatException);
  });

  test('limite de franquia é diferente de rate limit do servidor', () {
    expect(CommercialLimitMessage.isPlanLimit(
      'Sua franquia beta de chat acabou. Consulte seu plano.'), isTrue);
    expect(CommercialLimitMessage.isPlanLimit(
      'O servidor está ocupado ou atingiu o limite de requisições.'), isFalse);
    expect(CommercialLimitMessage.isPlanLimit('OpenRouter 429 rate limit'), isFalse);
    expect(CommercialLimitMessage.isPlanLimit('Saldo insuficiente para imagem'), isTrue);
  });

  testWidgets('mostra franquias como prévia, nunca como bloqueio ativo', (tester) async {
    await tester.pumpWidget(_app(CommercialScreen(
      requireGoogleAccount: false,
      loadAccount: () async => CommercialAccount.fromJson(_payload()),
    )));
    await tester.pumpAndSettle();
    expect(find.text('Meu plano e consumo'), findsOneWidget);
    expect(find.text('Pro'), findsOneWidget);
    expect(find.text('Franquias de teste — aplicação desativada'), findsOneWidget);
    expect(find.textContaining('sem bloqueio'), findsWidgets);
    expect(find.text('131 restantes hoje'), findsNothing);
    await tester.scrollUntilVisible(find.text('20 créditos'), 110);
    expect(find.text('20 créditos'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('mostra saldo restante apenas quando a franquia está ativa', (tester) async {
    await tester.pumpWidget(_app(CommercialScreen(
      requireGoogleAccount: false,
      loadAccount: () async => CommercialAccount.fromJson(_payload(enforced: true)),
    ), width: 350));
    await tester.pumpAndSettle();
    expect(find.text('Franquias de teste ativas'), findsOneWidget);
    expect(find.text('131 restantes hoje'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNWidgets(4));
    expect(tester.takeException(), isNull);
  });

  testWidgets('erro de consulta não mostra saldo antigo; tenta novamente', (tester) async {
    var calls = 0;
    await tester.pumpWidget(_app(CommercialScreen(
      requireGoogleAccount: false,
      loadAccount: () async {
        calls++;
        if (calls == 1) {
          throw const CommercialAccountException('Serviço indisponível para teste');
        }
        return CommercialAccount.fromJson(_payload());
      },
    )));
    await tester.pumpAndSettle();
    expect(find.text('Informações indisponíveis'), findsOneWidget);
    expect(find.text('Serviço indisponível para teste'), findsOneWidget);
    expect(find.text('20 créditos'), findsNothing);
    await tester.tap(find.text('Tentar novamente'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('20 créditos'), 110);
    expect(find.text('20 créditos'), findsOneWidget);
    expect(calls, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('erro de franquia pode abrir plano sem tentar geração paga', (tester) async {
    var opened = 0;
    await tester.pumpWidget(_app(Scaffold(body: ChatStatusIndicator(
      label: 'Você atingiu uma franquia disponível no seu plano.',
      isError: true,
      onViewPlan: () => opened++,
    )), width: 300));
    await tester.tap(find.text('Ver meu plano'));
    await tester.pump();
    expect(opened, 1);
    expect(tester.takeException(), isNull);
  });
}
