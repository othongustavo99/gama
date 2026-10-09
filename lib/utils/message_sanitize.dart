/// Limpa conteúdo de mensagens antes de enviar ao backend/LLM.
/// Remove base64 de imagens geradas e dumps enormes de anexos.
class MessageSanitize {
  static final _gamaImageRe = RegExp(
    r'\[gama_image\][\s\S]*?\[/gama_image\]',
    multiLine: true,
  );

  static final _projectDumpRe = RegExp(
    r'\[project_id:[^\]]+\][\s\S]{0,8000}?(?=(\n### |\n\[project_id:|\Z))',
    multiLine: true,
  );

  /// Limite duro por mensagem no histórico enviado à API (caracteres).
  static const int maxCharsPerMessage = 12000;

  /// Total aproximado máximo de caracteres no histórico (≈ tokens*4).
  static const int maxTotalChars = 280000; // ~70k tokens de texto, folga vs 400k

  static String forApi(String content) {
    var t = content;
    // Imagens geradas: não reenviar base64
    t = t.replaceAll(_gamaImageRe, '\n[imagem gerada anteriormente nesta conversa]\n');
    // ZIP index info verbosa: manter só project_id
    t = t.replaceAllMapped(_projectDumpRe, (m) {
      final id = RegExp(r'\[project_id:([^\]]+)\]').firstMatch(m.group(0)!);
      if (id != null) {
        return '[project_id:${id.group(1)}] Projeto indexado (conteúdo sob demanda no analyzer).';
      }
      return '[projeto indexado]';
    });
    t = t.trim();
    if (t.length > maxCharsPerMessage) {
      t = '${t.substring(0, maxCharsPerMessage)}\n\n…[conteúdo antigo cortado para caber no contexto]';
    }
    return t;
  }

  /// Aplica sanitização e corta o histórico pelo fim (mensagens recentes).
  static List<Map<String, String>> historyForApi(
    List<Map<String, String>> messages,
  ) {
    final cleaned = <Map<String, String>>[];
    for (final m in messages) {
      final role = m['role'] ?? 'user';
      final content = forApi(m['content'] ?? '');
      if (content.isEmpty) continue;
      cleaned.add({'role': role, 'content': content});
    }

    // Mantém do mais recente para o mais antigo até o orçamento
    final out = <Map<String, String>>[];
    var total = 0;
    for (var i = cleaned.length - 1; i >= 0; i--) {
      final c = cleaned[i]['content']!.length;
      if (out.isNotEmpty && total + c > maxTotalChars) break;
      out.insert(0, cleaned[i]);
      total += c;
    }
    return out;
  }
}
