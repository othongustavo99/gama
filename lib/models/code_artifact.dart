import '../utils/fenced_code.dart';

class CodeArtifactFile {
  const CodeArtifactFile({
    required this.name,
    required this.language,
    this.content,
    this.archiveIndex,
    this.size = 0,
  });

  final String name;
  final String language;
  final String? content;
  final int? archiveIndex;
  final int size;

  static List<CodeArtifactFile> fromMarkdown(String text) {
    final files = <CodeArtifactFile>[];
    for (final block in fencedCodeBlocks(text)) {
      if (block.end == null || block.contentEnd == block.contentStart) continue;
      final suffix = block.info.substring(block.language.length).trim();
      final named = RegExp(
        r'^(?:title=|filename=)?["\x27]?([\w./-]+\.[\w-]+)["\x27]?$',
      ).firstMatch(suffix)?.group(1);
      final extension = switch (block.language.toLowerCase()) {
        'javascript' || 'jsx' => 'js',
        'typescript' || 'tsx' => 'ts',
        'python' => 'py',
        'kotlin' => 'kt',
        'rust' => 'rs',
        'csharp' => 'cs',
        'bash' || 'shell' => 'sh',
        'markdown' => 'md',
        final value when RegExp(r'^[a-z0-9]{1,12}$').hasMatch(value) => value,
        _ => 'txt',
      };
      final content = block.content(text);
      files.add(
        CodeArtifactFile(
          name: named ?? 'trecho-${files.length + 1}.$extension',
          language: block.language,
          content: content,
          size: content.length,
        ),
      );
    }
    return files;
  }

  bool get isCode => !const {
    'text',
    'txt',
    'plaintext',
    'md',
    'markdown',
  }.contains(language.toLowerCase());

  bool get isLong {
    final text = content;
    return text != null &&
        (text.length >= 2000 || '\n'.allMatches(text).take(24).length == 24);
  }
}

class CodeArchive {
  const CodeArchive({
    required this.id,
    required this.name,
    this.sha256,
    this.size,
  });

  final String id;
  final String name;
  final String? sha256;
  final int? size;

  static List<CodeArchive> fromArtifacts(List<Map<String, dynamic>> artifacts) {
    return [
      for (final item in artifacts)
        if (item['kind'] == 'zip' &&
            RegExp(r'^[a-f0-9]{16}$')
                .hasMatch(item['artifact_id']?.toString() ?? ''))
          CodeArchive(
            id: item['artifact_id'].toString(),
            name: item['filename']?.toString() ?? 'arquivos.zip',
            sha256: item['sha256']?.toString(),
            size: int.tryParse(item['size']?.toString() ?? ''),
          ),
    ];
  }
}
