/// Comparador local de trechos de código para revisão na Oficina.
/// Não escreve nem modifica arquivos do projeto.
enum CodeDiffKind { context, added, removed }

class CodeDiffLine {
  final CodeDiffKind kind;
  final String text;
  final int? oldLine;
  final int? newLine;

  const CodeDiffLine(this.kind, this.text, this.oldLine, this.newLine);
}

class CodeDiffResult {
  final List<CodeDiffLine> lines;
  final int added;
  final int removed;
  final bool tooLarge;

  const CodeDiffResult({
    required this.lines,
    required this.added,
    required this.removed,
    this.tooLarge = false,
  });

  bool get hasChanges => added > 0 || removed > 0;
}

/// Calcula um diff por linhas usando LCS, com limite de memória/CPU.
/// Para arquivos grandes, não mostra um diff incompleto que poderia induzir
/// o usuário a pensar que viu todas as mudanças.
CodeDiffResult compareCode(
  String original,
  String candidate, {
  int maxLinesPerSide = 600,
}) {
  final a = original.replaceAll('\r\n', '\n').split('\n');
  final b = candidate.replaceAll('\r\n', '\n').split('\n');
  if (a.length > maxLinesPerSide || b.length > maxLinesPerSide) {
    return const CodeDiffResult(
      lines: [],
      added: 0,
      removed: 0,
      tooLarge: true,
    );
  }

  final n = a.length;
  final m = b.length;
  final lcs = List<List<int>>.generate(
    n + 1,
    (_) => List<int>.filled(m + 1, 0),
    growable: false,
  );
  for (var i = n - 1; i >= 0; i--) {
    for (var j = m - 1; j >= 0; j--) {
      lcs[i][j] = a[i] == b[j]
          ? 1 + lcs[i + 1][j + 1]
          : (lcs[i + 1][j] > lcs[i][j + 1] ? lcs[i + 1][j] : lcs[i][j + 1]);
    }
  }

  final lines = <CodeDiffLine>[];
  var i = 0;
  var j = 0;
  var added = 0;
  var removed = 0;
  while (i < n || j < m) {
    if (i < n && j < m && a[i] == b[j]) {
      lines.add(CodeDiffLine(CodeDiffKind.context, a[i], i + 1, j + 1));
      i++;
      j++;
    } else if (j < m && (i == n || lcs[i][j + 1] >= lcs[i + 1][j])) {
      lines.add(CodeDiffLine(CodeDiffKind.added, b[j], null, j + 1));
      added++;
      j++;
    } else {
      lines.add(CodeDiffLine(CodeDiffKind.removed, a[i], i + 1, null));
      removed++;
      i++;
    }
  }
  return CodeDiffResult(lines: lines, added: added, removed: removed);
}
