/// A fenced block and its source offsets. An open block has no [end].
class FencedCode {
  const FencedCode({
    required this.start,
    required this.contentStart,
    required this.contentEnd,
    required this.end,
    required this.info,
  });

  final int start;
  final int contentStart;
  final int contentEnd;
  final int? end;
  final String info;

  String get language => info.split(RegExp(r'\s+')).first;
  String content(String text) => text.substring(contentStart, contentEnd);
}

final _fenceLine = RegExp(
  r'^ {0,3}(`{3,}|~{3,})([^\r\n]*)(\r?\n|$)',
  multiLine: true,
);

Iterable<FencedCode> fencedCodeBlocks(
  String text, {
  bool streaming = false,
}) sync* {
  RegExpMatch? opening;
  for (final match in _fenceLine.allMatches(text)) {
    final fence = match.group(1)!;
    final info = match.group(2)!.trim();
    final completeLine = match.group(3)!.isNotEmpty;
    final current = opening;
    if (current == null) {
      if (completeLine && (!fence.startsWith('`') || !info.contains('`'))) {
        opening = match;
      }
      continue;
    }
    final opener = current.group(1)!;
    if (fence[0] != opener[0] ||
        fence.length < opener.length ||
        info.isNotEmpty ||
        (streaming && !completeLine)) {
      continue;
    }
    var contentEnd = match.start;
    if (contentEnd > current.end && text.codeUnitAt(contentEnd - 1) == 10) {
      contentEnd--;
      if (contentEnd > current.end && text.codeUnitAt(contentEnd - 1) == 13) {
        contentEnd--;
      }
    }
    yield FencedCode(
      start: current.start,
      contentStart: current.end,
      contentEnd: contentEnd,
      end: match.end,
      info: current.group(2)!.trim(),
    );
    opening = null;
  }
  if (opening != null) {
    yield FencedCode(
      start: opening.start,
      contentStart: opening.end,
      contentEnd: text.length,
      end: null,
      info: opening.group(2)!.trim(),
    );
  }
}
