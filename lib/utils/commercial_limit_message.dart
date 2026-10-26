/// Distingue franquias do plano de congestionamento/limites temporários da API.
/// A classificação deve ser conservadora: um HTTP 429 sozinho não indica plano.
class CommercialLimitMessage {
  static bool isPlanLimit(String? message) {
    if (message == null) return false;
    final text = message.toLowerCase();
    return (text.contains('franquia') &&
        (text.contains('acabou') || text.contains('esgotad') ||
         text.contains('atingi') || text.contains('exced'))) ||
        text.contains('créditos insuficientes') ||
        text.contains('saldo insuficiente para') ||
        text.contains('limite do seu plano');
  }

  static String display(String detail) {
    if (isPlanLimit(detail)) {
      return 'Você atingiu uma franquia disponível no seu plano. '
          'Consulte seu consumo e o horário de renovação das cotas.';
    }
    return detail;
  }
}
