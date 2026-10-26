import 'package:flutter_test/flutter_test.dart';
import 'package:gama/services/admin_service.dart';

void main() {
  test('resume custos informados, modelos e reservas sem confundir faturamento', () {
    final report = AdminOverview.fromJson({
      'period_days': 7, 'active_users_in_period': 5, 'requests_total': 42,
      'billing_enabled': false,
      'media_reservations': {'image': 3, 'video': 1},
      'daily': [{'day': '2026-10-26', 'requests': 42}],
      'provider_usage': {
        'llm_and_media_calls': 8, 'reported_cost_usd': 0.122,
        'unknown_cost_calls': 2,
        'models': [
          {'model': 'model-a', 'category': 'chat', 'calls': 5,
           'reported_cost_usd': 0.12, 'unknown_cost_calls': 2},
          {'model': 'model-b', 'category': 'image', 'calls': 3,
           'reported_cost_usd': 0.002, 'unknown_cost_calls': 0},
        ],
      },
    });
    expect(report.users, 5);
    expect(report.requests, 42);
    expect(report.calls, 8);
    expect(report.billingEnabled, isFalse);
    expect(report.unknownCosts, 2);
    expect(report.models.first.model, 'model-a');
    expect(report.mediaReservations['video'], 1);
  });

  test('resposta incompleta não vira relatório financeiro artificial', () {
    expect(() => AdminOverview.fromJson({'provider_usage': {}}),
      throwsA(isA<AdminException>()));
  });

  test('parsing do alvo exige saldo e proprietário', () {
    expect(AdminAccount.fromJson({
      'account_id': 'google_email_test@example.com',
      'plan': 'pro', 'plan_expires_at': null, 'credits_balance': 9,
    }).balance, 9);
    expect(() => AdminAccount.fromJson({'plan':'free'}),
      throwsA(isA<AdminException>()));
  });
}
