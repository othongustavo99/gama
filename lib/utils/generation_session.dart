/// Evita que callbacks tardios de uma requisição cancelada finalizem
/// outra resposta ou apaguem o estado da conversa atual.
class GenerationSession {
  int _epoch = 0;

  int start() => ++_epoch;

  void invalidate() => _epoch++;

  bool isCurrent(int token) => token == _epoch;
}
