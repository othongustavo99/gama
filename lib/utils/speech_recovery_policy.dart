/// Política de recuperação do reconhecimento de fala.
/// Erros permanentes não provocam reconexão infinita; falhas temporárias
/// usam espera progressiva com limite. Encerramento normal por silêncio
/// não é contabilizado como falha.
class SpeechRecoveryPolicy {
  SpeechRecoveryPolicy({this.maxFailures = 5}) : assert(maxFailures > 0);

  final int maxFailures;
  int _consecutiveFailures = 0;

  int get consecutiveFailures => _consecutiveFailures;

  void reset() => _consecutiveFailures = 0;

  Duration? recordFailure({required bool permanent}) {
    if (permanent) {
      _consecutiveFailures = maxFailures;
      return null;
    }
    _consecutiveFailures++;
    if (_consecutiveFailures >= maxFailures) return null;
    final milliseconds = (650 * (1 << (_consecutiveFailures - 1)))
        .clamp(650, 8000)
        .toInt();
    return Duration(milliseconds: milliseconds);
  }
}
