/// Snapshot consultado diretamente no backend autenticado da Gamma.
/// Valores de franquia beta NÃO equivalem a saldo financeiro.
class CommercialAccount {
  final String plan;
  final DateTime? expiresAt;
  final int creditsBalance;
  final Map<String, int> limits;
  final Map<String, int> usageToday;
  final DateTime dayUtc;
  final bool enforcementActive;
  final bool paymentsActive;
  final bool limitsPreviewOnly;

  const CommercialAccount({
    required this.plan,
    required this.expiresAt,
    required this.creditsBalance,
    required this.limits,
    required this.usageToday,
    required this.dayUtc,
    required this.enforcementActive,
    required this.paymentsActive,
    required this.limitsPreviewOnly,
  });

  static Map<String, int> _counts(Object? raw, String field) {
    if (raw is! Map) throw FormatException('Campo $field ausente');
    final result = <String, int>{};
    for (final entry in raw.entries) {
      if (entry.key is! String || entry.value is! int || entry.value < 0) {
        throw FormatException('Campo $field inválido');
      }
      result[entry.key as String] = entry.value as int;
    }
    return Map.unmodifiable(result);
  }

  factory CommercialAccount.fromJson(Map<String, dynamic> data) {
    final plan = data['plan'];
    final credits = data['credits_balance'];
    final day = data['day_utc'];
    final enforcement = data['enforcement_active'];
    final payments = data['payments_active'];
    final preview = data['limits_preview_only'];
    if (plan is! String || plan.trim().isEmpty ||
        credits is! int || credits < 0 ||
        day is! String || enforcement is! bool ||
        payments is! bool || preview is! bool) {
      throw const FormatException('Resumo comercial incompleto');
    }
    final parsedDay = RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(day)
        ? DateTime.tryParse('${day}T00:00:00Z')
        : null;
    if (parsedDay == null) {
      throw const FormatException('Data de consumo inválida');
    }
    final expiryRaw = data['plan_expires_at'];
    DateTime? expiry;
    if (expiryRaw != null) {
      if (expiryRaw is! String || DateTime.tryParse(expiryRaw) == null) {
        throw const FormatException('Validade do plano inválida');
      }
      expiry = DateTime.parse(expiryRaw);
    }
    return CommercialAccount(
      plan: plan,
      expiresAt: expiry,
      creditsBalance: credits,
      limits: _counts(data['limits'], 'limits'),
      usageToday: _counts(data['usage_today'], 'usage_today'),
      dayUtc: parsedDay.toUtc(),
      enforcementActive: enforcement,
      paymentsActive: payments,
      limitsPreviewOnly: preview,
    );
  }

  String get displayPlan => switch (plan.toLowerCase()) {
    'free' => 'Gratuito',
    'pro' => 'Pro',
    'creator' => 'Creator',
    _ => plan,
  };

  int used(String feature) => usageToday[feature] ?? 0;
  int? limit(String feature) => limits[feature];
  int? remaining(String feature) {
    final maximum = limit(feature);
    if (!enforcementActive || limitsPreviewOnly || maximum == null) return null;
    final left = maximum - used(feature);
    return left < 0 ? 0 : left;
  }
}
