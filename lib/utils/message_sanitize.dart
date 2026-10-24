/// Limpa conteúdo de mensagens antes de enviar ao backend/LLM.
/// Remove base64 de imagens geradas e dumps enormes de anexos.
class MessageSanitize {
  static final _gamaImageRe = RegExp(
    r'\[gama_image\][\s\S]*?\[/gama_image\]',
    multiLine: true,
  );

  static final _gamaImageFileRe = RegExp(
    r'\[gama_image_file\][\s\S]*?\[/gama_image_file\]',
    multiLine: true,
  );

  static final _projectDumpRe = RegExp(
    r'\[project_id:[^\]]+\][\s\S]{0,8000}?(?=(\n### |\n\[project_id:|\Z))',
    multiLine: true,
  );

  /// Limite duro por mensagem no histórico enviado à API (caracteres).
  static const int maxCharsPerMessage = 12000;
  static const int maxCharsCurrentUser = 100000;

  /// Total aproximado máximo de caracteres no histórico (≈ tokens*4).
  static const int maxTotalChars =
      280000; // ~70k tokens de texto, folga vs 400k

  static String forApi(String content, {int maxChars = maxCharsPerMessage}) {
    var t = content;
    // Imagens geradas: não reenviar base64
    t = t.replaceAll(
      _gamaImageRe,
      '\n[imagem gerada anteriormente nesta conversa]\n',
    );
    t = t.replaceAll(
      _gamaImageFileRe,
      '\n[imagem gerada anteriormente nesta conversa]\n',
    );
    // ZIP index info verbosa: manter só project_id
    t = t.replaceAllMapped(_projectDumpRe, (m) {
      final id = RegExp(r'\[project_id:([^\]]+)\]').firstMatch(m.group(0)!);
      if (id != null) {
        return '[project_id:${id.group(1)}] Projeto indexado (conteúdo sob demanda no analyzer).';
      }
      return '[projeto indexado]';
    });
    t = t.trim();
    if (t.length > maxChars) {
      // Histórico antigo recebe cabeça e final; não deixa um arquivo entregue
      // pela metade sem avisar. Mensagem atual preserva até 100 mil caracteres.
      if (maxChars == maxCharsCurrentUser) {
        t = '${t.substring(0, maxChars)}\n\n…[mensagem atual excedeu o limite; envie como anexo]';
      } else {
        final head = (maxChars * 0.65).round();
        final tail = maxChars - head;
        t = '${t.substring(0, head)}\n\n[trecho intermediário de mensagem/arquivo antigo omitido]\n\n${t.substring(t.length - tail)}';
      }
    }
    return t;
  }

  /// Aplica sanitização e corta o histórico pelo fim (mensagens recentes).
  static List<Map<String, String>> historyForApi(
    List<Map<String, String>> messages,
  ) {
    final cleaned = <Map<String, String>>[];
    final latestUser = messages.lastIndexWhere((m) => m['role'] == 'user');
    for (var index = 0; index < messages.length; index++) {
      final m = messages[index];
      final role = m['role'] ?? 'user';
      // O servidor é a única fonte de instruções system.
      if (role == 'system') continue;
      final content = forApi(
        m['content'] ?? '',
        maxChars: index == latestUser ? maxCharsCurrentUser : maxCharsPerMessage,
      );
      if (content.isEmpty) continue;
      cleaned.add({
        'role': role,
        'content': content,
        if ((m['id'] ?? '').isNotEmpty) 'id': m['id']!,
      });
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
