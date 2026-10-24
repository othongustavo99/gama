/// Segmenta tokens de um stream em frases completas para TTS.
/// Nunca inventa pontuação nem envia palavras incompletas enquanto recebe.
class SpeechSentenceAccumulator {
  String _pending = '';
  static const int maxPendingCharacters = 260;

  List<String> append(String token) {
    if (token.isEmpty) return const [];
    _pending += token;
    return _drain(flush: false);
  }

  List<String> finish() => _drain(flush: true);

  void clear() => _pending = '';

  List<String> _drain({required bool flush}) {
    final parts = <String>[];
    while (_pending.isNotEmpty) {
      // Ponto de frase só é seguro quando há espaço, nova linha ou fim real.
      final match = RegExp(r'[.!?…]+(?=\s)').firstMatch(_pending);
      int cut = match?.end ?? -1;
      if (cut < 0 && _pending.length > maxPendingCharacters) {
        // Falas longas: quebrar em espaço, nunca no meio da palavra.
        cut = _pending.lastIndexOf(' ', maxPendingCharacters);
      }
      if (cut <= 0) {
        if (!flush) break;
        cut = _pending.length;
      }
      final candidate = _pending.substring(0, cut).trim();
      _pending = _pending.substring(cut).trimLeft();
      if (candidate.isNotEmpty) parts.add(candidate);
    }
    return parts;
  }
}
