/// Filtra blocos internos de mídia/artefatos APENAS da apresentação do chat.
/// O conteúdo bruto continua intacto para a API, ZIPs e persistência.
///
/// Suporta marcadores partidos entre chunks de NDJSON sem reter os dados
/// grandes (por exemplo, base64 de imagens ou código integral de arquivos).
class GamaStreamDisplayFilter {
  static const Map<String, String> _blocks = {
    '[[GAMA_FILES]]': '[[/GAMA_FILES]]',
    '[gama_image_file]': '[/gama_image_file]',
    '[gama_image]': '[/gama_image]',
    '[[GAMA_SUMMARY]]': '[[/GAMA_SUMMARY]]',
  };

  String _pending = '';
  String? _closing;

  void reset() {
    _pending = '';
    _closing = null;
  }

  String append(String chunk) {
    if (chunk.isEmpty) return '';
    _pending += chunk;
    final visible = StringBuffer();

    while (_pending.isNotEmpty) {
      final closing = _closing;
      if (closing != null) {
        final finish = _pending.indexOf(closing);
        if (finish >= 0) {
          _pending = _pending.substring(finish + closing.length);
          _closing = null;
          continue;
        }
        // Pode haver um fechamento dividido entre dois chunks.
        final keep = closing.length - 1;
        if (_pending.length > keep) {
          _pending = _pending.substring(_pending.length - keep);
        }
        break;
      }

      String? opener;
      var index = _pending.length;
      for (final candidate in _blocks.keys) {
        final current = _pending.indexOf(candidate);
        if (current >= 0 && current < index) {
          index = current;
          opener = candidate;
        }
      }
      if (opener != null) {
        visible.write(_pending.substring(0, index));
        // Nunca revele o bloco interno, mas mostre progresso humano.
        visible.write('\n\nPreparando conteúdo e arquivos…\n\n');
        _pending = _pending.substring(index + opener.length);
        _closing = _blocks[opener];
        continue;
      }

      // Segura somente um possível prefixo de marcador incompleto.
      var keep = 0;
      for (final candidate in _blocks.keys) {
        final upper = candidate.length - 1 < _pending.length
            ? candidate.length - 1
            : _pending.length;
        for (var length = upper; length > keep; length--) {
          if (_pending.endsWith(candidate.substring(0, length))) {
            keep = length;
            break;
          }
        }
      }
      visible.write(_pending.substring(0, _pending.length - keep));
      _pending = _pending.substring(_pending.length - keep);
      break;
    }
    return visible.toString();
  }
}
