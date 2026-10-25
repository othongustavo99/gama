/// Revela apenas palavras que já foram alcançadas pela reprodução do áudio.
///
/// O player fornece uma fração entre 0 e 1 para cada trecho de TTS. A parte
/// já falada é mantida, mesmo ao trocar de trecho. Não depende de Flutter,
/// permitindo testar o algoritmo isoladamente.
class SpeechRevealBuffer {
  final StringBuffer _completed = StringBuffer();
  String _active = '';
  double _progress = 0;
  String _visible = '';

  String get value => _visible;

  void reset() {
    _completed.clear();
    _active = '';
    _progress = 0;
    _visible = '';
  }

  String advance(String chunk, double fraction) {
    if (chunk.isEmpty) return _visible;
    if (chunk != _active) {
      // O início do próximo segmento confirma a conclusão do anterior.
      // Esse caminho também atende players que não reportam 100% da posição.
      if (_active.isNotEmpty) _commit(_active);
      _active = chunk;
      _progress = 0;
    }
    _progress = fraction.isNaN ? _progress :
        fraction.clamp(_progress, 1.0).toDouble();
    final isComplete = _progress >= 0.999;
    final limit = isComplete ? chunk.length : (chunk.length * _progress).floor();
    var boundary = 0;
    // A posição da reprodução pode chegar no meio de uma palavra ou emoji.
    // Só avançamos por palavras inteiras, evitando caracteres quebrados.
    for (final match in RegExp(r'\S+\s*').allMatches(chunk)) {
      if (match.end > limit) break;
      boundary = match.end;
    }
    final spokenPart = isComplete ? chunk : chunk.substring(0, boundary);
    _visible = _join(_completed.toString(), spokenPart);
    if (isComplete) {
      _commit(chunk);
      _active = '';
      _progress = 0;
      _visible = _completed.toString();
    }
    return _visible;
  }

  void _commit(String chunk) {
    if (_completed.isNotEmpty) _completed.write(' ');
    _completed.write(chunk.trim());
  }

  static String _join(String complete, String current) {
    if (complete.isEmpty) return current.trimRight();
    if (current.isEmpty) return complete;
    return '$complete ${current.trimRight()}';
  }
}
