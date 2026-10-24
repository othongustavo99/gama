/// Janela de renderização do histórico. Não altera o Hive nem o contexto
/// enviado ao modelo: apenas limita quantos balões o ListView constrói.
///
/// A janela é ancorada nas mensagens mais recentes. Ao carregar anteriores,
/// amplia-se a janela sem modificar índices reais (ações/edições continuam
/// apontando para a posição da mensagem no histórico completo).
class ChatHistoryWindow {
  ChatHistoryWindow({this.initialSize = 60, this.pageSize = 40})
      : assert(initialSize > 0),
        assert(pageSize > 0),
        _visibleCount = initialSize;

  final int initialSize;
  final int pageSize;
  int _visibleCount;

  int get visibleCount => _visibleCount;

  void reset() => _visibleCount = initialSize;

  int start(int total) => total > _visibleCount ? total - _visibleCount : 0;

  int remaining(int total) => start(total);

  int count(int total) => total - start(total);

  bool hasOlder(int total) => remaining(total) > 0;

  /// Número efetivamente disponibilizado ao tocar 'Carregar anteriores'.
  int loadEarlier(int total) {
    final before = remaining(total);
    if (before == 0) return 0;
    final loaded = before < pageSize ? before : pageSize;
    _visibleCount += loaded;
    return loaded;
  }

  /// Converte o índice renderizado em índice do histórico completo.
  /// Se o cabeçalho "Carregar anteriores" está presente, ocupa a posição 0.
  int messageIndex(int listIndex, int total) =>
      start(total) + listIndex - (hasOlder(total) ? 1 : 0);

  int listLength(int total) =>
      count(total) + (hasOlder(total) ? 1 : 0);
}
