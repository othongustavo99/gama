import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_highlight/themes/github.dart';
import 'package:flutter_highlight/themes/monokai.dart';
import 'package:highlight/highlight.dart' show highlight, Node;
import 'package:markdown/markdown.dart' as md;
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/gama_colors.dart';
import '../services/download_service.dart';

class ParsedMessage {
  final String text;
  final List<AttachmentPreview> attachments;
  final List<GeneratedImageData> images;

  const ParsedMessage({
    required this.text,
    required this.attachments,
    this.images = const [],
  });
}

class GeneratedImageData {
  final String mime;
  final String base64;
  final String? filePath;
  const GeneratedImageData({
    required this.mime,
    this.base64 = '',
    this.filePath,
  });
}

class AttachmentPreview {
  final String name;
  final String kindLabel;
  final String body;
  final int? bytes;

  const AttachmentPreview({
    required this.name,
    required this.kindLabel,
    this.body = '',
    this.bytes,
  });
}

final _gamaImageAnyRe = RegExp(
  r'\[gama_image_file\]\s*mime:([^\n]+)\s*path:([^\n]+)\s*\[/gama_image_file\]'
  r'|\[gama_image\]\s*mime:([^\n]+)\s*data:([A-Za-z0-9+/=\s]+)\s*\[/gama_image\]',
  multiLine: true,
);

class _TexMathInlineSyntax extends md.InlineSyntax {
  _TexMathInlineSyntax()
    : super(r'(?<!\\)\$\$([\s\S]+?)\$\$|(?<!\\)\$([^\n$]+?)\$|\\\[([\s\S]+?)\\\]|\\\((.+?)\\\)');

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final expression = match[1] ?? match[2] ?? match[3] ?? match[4] ?? '';
    final element = md.Element.text('math', expression.trim());
    element.attributes['display'] = (match[1] != null || match[3] != null)
        ? 'true'
        : 'false';
    parser.addNode(element);
    return true;
  }
}

class _TexMathBuilder extends MarkdownElementBuilder {
  final TextStyle? textStyle;

  _TexMathBuilder(this.textStyle);

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final display = element.attributes['display'] == 'true';
    return Math.tex(
      element.textContent,
      mathStyle: display ? MathStyle.display : MathStyle.text,
      textStyle: (preferredStyle ?? textStyle)?.copyWith(
        color: (preferredStyle ?? textStyle)?.color ?? context.gama.textPrimary,
      ),
      onErrorFallback: (_) => Text(element.textContent),
    );
  }
}

(String, List<GeneratedImageData>) extractGamaImages(String content) {
  final images = <GeneratedImageData>[];
  final text = content.replaceAllMapped(_gamaImageAnyRe, (m) {
    if (m.group(1) != null) {
      images.add(
        GeneratedImageData(
          mime: m.group(1)!.trim(),
          filePath: m.group(2)!.trim(),
        ),
      );
    } else {
      images.add(
        GeneratedImageData(
          mime: m.group(3)!.trim(),
          base64: m.group(4)!.replaceAll(RegExp(r'\s'), ''),
        ),
      );
    }
    return '';
  });
  return (text.trim(), images);
}

ParsedMessage parseMessageContent(String content) {
  final raw = content.trim();
  if (raw.isEmpty) {
    return const ParsedMessage(text: '', attachments: []);
  }

  final marker = RegExp(r'\n*Anexos para análise:\s*\n?', caseSensitive: false);
  final m = marker.firstMatch(raw);

  String mainText;
  String section;

  if (m != null) {
    mainText = raw.substring(0, m.start).trim();
    section = raw.substring(m.end).trim();
  } else if (_looksLikeDump(raw)) {
    final name = _guessName(raw);
    return ParsedMessage(
      text: '',
      attachments: [
        AttachmentPreview(
          name: name,
          kindLabel: raw.contains('(ZIP)') || raw.contains('.zip')
              ? 'ZIP'
              : raw.contains('(PDF)') || raw.contains('.pdf')
              ? 'PDF'
              : 'arquivo',
          body: raw.length > 3000 ? '${raw.substring(0, 3000)}\n…' : raw,
        ),
      ],
    );
  } else {
    return ParsedMessage(text: raw, attachments: const []);
  }

  final attachments = <AttachmentPreview>[];
  final blocks = section.split(RegExp(r'\n(?=### )'));
  for (final block in blocks) {
    final t = block.trim();
    if (t.isEmpty) continue;
    final lines = t.split('\n');
    var title = lines.first.replaceFirst(RegExp(r'^###\s*'), '').trim();
    var kind = 'arquivo';
    final kindM = RegExp(
      r'\((ZIP|PDF|imagem|áudio|audio|código|codigo|arquivo)\)',
      caseSensitive: false,
    ).firstMatch(title);
    if (kindM != null) {
      kind = kindM.group(1)!;
      title = title.replaceAll(kindM.group(0)!, '').trim();
    }
    int? bytes;
    final meta = RegExp(r'\[arquivo:([^\|\]]*)\|(\d+)\]').firstMatch(t);
    if (meta != null) {
      bytes = int.tryParse(meta.group(2)!);
    }
    var body = t;
    body = body.replaceFirst(RegExp(r'^###[^\n]*\n'), '');
    body = body.replaceAll(RegExp(r'\[arquivo:[^\]]+\]'), '').trim();
    body = body.replaceAll(RegExp(r'\[project_id:[^\]]+\]'), '').trim();
    if (body.length < 8) body = '';

    attachments.add(
      AttachmentPreview(
        name: title.isEmpty ? 'Anexo' : title,
        kindLabel: kind,
        body: body,
        bytes: bytes,
      ),
    );
  }

  if (attachments.isEmpty && section.isNotEmpty) {
    attachments.add(
      const AttachmentPreview(name: 'Anexo', kindLabel: 'arquivo'),
    );
  }

  return ParsedMessage(text: mainText, attachments: attachments);
}

bool _looksLikeDump(String raw) {
  if (raw.length < 400) return false;
  if ('```'.allMatches(raw).length >= 2) return true;
  if (raw.contains('(ZIP)') || (raw.contains('### ') && raw.length > 800)) {
    return true;
  }
  return false;
}

String _guessName(String raw) {
  final m = RegExp(r'^###\s*(.+)').firstMatch(raw);
  if (m != null) return m.group(1)!.trim();
  return 'Arquivo anexado';
}

String _fmtBytes(int? b) {
  if (b == null) return '';
  if (b < 1024) return '$b B';
  if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
  return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
}

Future<String> _saveImageFile({
  required String? sourcePath,
  required String base64Data,
  required String mime,
}) {
  if (sourcePath != null && sourcePath.isNotEmpty) {
    return DownloadService.instance.copyFile(sourcePath);
  }
  return DownloadService.instance.saveBase64Image(base64Data, mime: mime);
}

Future<void> _shareImageFile(
  BuildContext context, {
  required String? sourcePath,
  required String base64Data,
  required String mime,
}) async {
  try {
    final path =
        sourcePath ??
        await _saveImageFile(
          sourcePath: null,
          base64Data: base64Data,
          mime: mime,
        );
    await SharePlus.instance.share(
      ShareParams(files: [XFile(path)], title: 'Imagem da Gama'),
    );
  } catch (error) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Não consegui compartilhar a imagem: $error')),
    );
  }
}

class _FullscreenImageDialog extends StatelessWidget {
  final Widget image;
  final String? sourcePath;
  final String base64Data;
  final String mime;

  const _FullscreenImageDialog({
    required this.image,
    required this.sourcePath,
    required this.base64Data,
    required this.mime,
  });

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return Dialog(
      insetPadding: const EdgeInsets.all(8),
      backgroundColor: const Color(0xFF080808),
      child: SizedBox(
        width: size.width,
        height: size.height,
        child: Stack(
          children: [
            Positioned.fill(
              child: InteractiveViewer(
                minScale: 0.5,
                maxScale: 5,
                child: Center(child: image),
              ),
            ),
            SafeArea(
              child: Align(
                alignment: Alignment.topRight,
                child: IconButton.filledTonal(
                  tooltip: 'Fechar',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close_rounded),
                ),
              ),
            ),
            SafeArea(
              child: Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Material(
                    color: Colors.black.withValues(alpha: 0.68),
                    borderRadius: BorderRadius.circular(16),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          TextButton.icon(
                            onPressed: () async {
                              try {
                                await _saveImageFile(
                                  sourcePath: sourcePath,
                                  base64Data: base64Data,
                                  mime: mime,
                                );
                                if (!context.mounted) return;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('Imagem salva')),
                                );
                              } catch (error) {
                                if (!context.mounted) return;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      'Não consegui salvar a imagem: $error',
                                    ),
                                  ),
                                );
                              }
                            },
                            icon: const Icon(Icons.download_outlined),
                            label: const Text('Salvar'),
                          ),
                          TextButton.icon(
                            onPressed: () => _shareImageFile(
                              context,
                              sourcePath: sourcePath,
                              base64Data: base64Data,
                              mime: mime,
                            ),
                            icon: const Icon(Icons.share_outlined),
                            label: const Text('Compartilhar'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class MessageContentView extends StatelessWidget {
  final String content;
  final bool isUser;
  final void Function(String? href)? onTapLink;

  const MessageContentView({
    super.key,
    required this.content,
    required this.isUser,
    this.onTapLink,
  });

  @override
  Widget build(BuildContext context) {
    final extracted = extractGamaImages(content);
    final parsed = isUser
        ? parseMessageContent(extracted.$1)
        : ParsedMessage(
            text: extracted.$1,
            attachments: const [],
            images: extracted.$2,
          );
    final images = isUser ? extracted.$2 : parsed.images;

    final textStyle = TextStyle(
      color: isUser ? Colors.white : context.gama.textPrimary,
      fontSize: 15,
      height: 1.55,
      letterSpacing: 0.1,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (images.isNotEmpty) ...[
          ...images.map((img) {
            final filePath = img.filePath;
            final fileExists =
                filePath != null &&
                filePath.isNotEmpty &&
                File(filePath).existsSync();
            if (!fileExists && img.base64.isEmpty) {
              return Padding(
                padding: EdgeInsets.only(bottom: 10),
                child: Text(
                  '[imagem indisponível]',
                  style: TextStyle(color: context.gama.textMuted),
                ),
              );
            }
            try {
              final memoryBytes = img.base64.isEmpty
                  ? null
                  : base64Decode(img.base64);
              final imageWidget = fileExists
                  ? Image.file(
                      File(filePath!),
                      fit: BoxFit.contain,
                      gaplessPlayback: true,
                      errorBuilder: (_, __, ___) => Text(
                        '[imagem indisponível]',
                        style: TextStyle(color: context.gama.textMuted),
                      ),
                    )
                  : Image.memory(
                      memoryBytes!,
                      fit: BoxFit.contain,
                      gaplessPlayback: true,
                      errorBuilder: (_, __, ___) => Text(
                        '[imagem indisponível]',
                        style: TextStyle(color: context.gama.textMuted),
                      ),
                    );
              return Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Semantics(
                      button: true,
                      label: 'Abrir imagem em tela cheia',
                      child: GestureDetector(
                        onTap: () => showDialog<void>(
                          context: context,
                          barrierColor: Colors.black87,
                          builder: (_) => _FullscreenImageDialog(
                            image: fileExists
                                ? Image.file(
                                    File(filePath!),
                                    fit: BoxFit.contain,
                                  )
                                : Image.memory(
                                    memoryBytes!,
                                    fit: BoxFit.contain,
                                  ),
                            sourcePath: fileExists ? filePath : null,
                            base64Data: img.base64,
                            mime: img.mime,
                          ),
                        ),
                        child: MouseRegion(
                          cursor: SystemMouseCursors.click,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(14),
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxHeight: 480),
                              child: imageWidget,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Align(
                      alignment: Alignment.centerRight,
                      child: Wrap(
                        spacing: 4,
                        children: [
                          TextButton.icon(
                            style: TextButton.styleFrom(
                              foregroundColor: context.gama.accent,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                              ),
                              visualDensity: VisualDensity.compact,
                            ),
                            onPressed: () async {
                              try {
                                final path = await _saveImageFile(
                                  sourcePath: fileExists ? filePath : null,
                                  base64Data: img.base64,
                                  mime: img.mime,
                                );
                                await DownloadService.instance.openPath(path);
                              } catch (_) {}
                            },
                            icon: const Icon(Icons.download_rounded, size: 18),
                            label: const Text('Salvar imagem'),
                          ),
                          TextButton.icon(
                            onPressed: () => _shareImageFile(
                              context,
                              sourcePath: fileExists ? filePath : null,
                              base64Data: img.base64,
                              mime: img.mime,
                            ),
                            icon: const Icon(Icons.share_outlined, size: 17),
                            label: const Text('Compartilhar'),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            } catch (_) {
              return const SizedBox.shrink();
            }
          }),
        ],
        if (parsed.text.isNotEmpty)
          _MarkdownMessage(
            text: parsed.text,
            isUser: isUser,
            textStyle: textStyle,
            onTapLink: onTapLink,
          ),
        if (parsed.attachments.isNotEmpty) ...[
          if (parsed.text.isNotEmpty) const SizedBox(height: 10),
          ...parsed.attachments.map(
            (a) => Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: _AttachmentChip(preview: a, isUser: isUser),
            ),
          ),
        ],
      ],
    );
  }

  static String _linkifyBareUrls(String text) {
    final re = RegExp(r'(?<!\()(https?:\/\/[^\s\)\]]+)', caseSensitive: false);
    return text.replaceAllMapped(re, (m) {
      var url = m.group(1)!;
      var trail = '';
      while (url.isNotEmpty && '.,;:!?'.contains(url[url.length - 1])) {
        trail = url[url.length - 1] + trail;
        url = url.substring(0, url.length - 1);
      }
      return '[$url]($url)$trail';
    });
  }
}

/// Mantém árvores Markdown finalizadas prontas entre reconstruções da tela.
class MemoizedMessageContentView extends StatefulWidget {
  final String content;
  final bool isUser;
  final void Function(String? href)? onTapLink;

  const MemoizedMessageContentView({
    super.key,
    required this.content,
    required this.isUser,
    this.onTapLink,
  });

  @override
  State<MemoizedMessageContentView> createState() =>
      _MemoizedMessageContentViewState();
}

class _MemoizedMessageContentViewState
    extends State<MemoizedMessageContentView> {
  late Widget _cachedContent = _createContent();

  Widget _createContent() => MessageContentView(
    content: widget.content,
    isUser: widget.isUser,
    onTapLink: widget.onTapLink,
  );

  @override
  void didUpdateWidget(covariant MemoizedMessageContentView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.content != widget.content ||
        oldWidget.isUser != widget.isUser) {
      _cachedContent = _createContent();
    }
  }

  @override
  Widget build(BuildContext context) => _cachedContent;
}

/// Renderiza Markdown normalmente, mas separa blocos cercados por ``` em
/// caixas próprias. Isso permite colocar o botão de copiar sem interferir
/// no restante do Markdown já usado pela Gama.
class _MarkdownMessage extends StatelessWidget {
  final String text;
  final bool isUser;
  final TextStyle textStyle;
  final void Function(String? href)? onTapLink;

  const _MarkdownMessage({
    required this.text,
    required this.isUser,
    required this.textStyle,
    required this.onTapLink,
  });

  @override
  Widget build(BuildContext context) {
    final parts = _splitCodeBlocks(text);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final part in parts)
          if (part.isCode)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: RepaintBoundary(
                child: _CopyableCodeBlock(
                  code: part.content,
                  language: part.language,
                  isUser: isUser,
                  textStyle: textStyle,
                ),
              ),
            )
          else if (part.content.trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: MarkdownBody(
                data: MessageContentView._linkifyBareUrls(part.content),
                selectable: true,
                inlineSyntaxes: [_TexMathInlineSyntax()],
                onTapLink: (linkText, href, title) {
                  if (onTapLink != null) {
                    onTapLink!(href);
                  } else if (href != null) {
                    launchUrl(
                      Uri.parse(href),
                      mode: LaunchMode.externalApplication,
                    );
                  }
                },
                builders: {
                  'math': _TexMathBuilder(textStyle),
                  'table': _HScrollTableBuilder(
                    isUser: isUser,
                    onTapLink: onTapLink,
                  ),
                },
                styleSheet: _markdownStyleSheet(
                  isUser,
                  textStyle,
                  context.gama,
                ),
              ),
            ),
      ],
    );
  }

  static MarkdownStyleSheet _markdownStyleSheet(
    bool isUser,
    TextStyle textStyle,
    GamaPalette palette,
  ) {
    return MarkdownStyleSheet(
      p: textStyle,
      a: textStyle.copyWith(
        color: isUser ? Colors.white : palette.accent,
        decoration: TextDecoration.underline,
        decorationColor: isUser ? Colors.white70 : palette.accent,
      ),
      code: textStyle.copyWith(
        fontSize: 13,
        fontFamily: 'monospace',
        color: isUser ? Colors.white : const Color(0xFFF4F4F5),
        backgroundColor: isUser
            ? Colors.black.withValues(alpha: 0.24)
            : const Color(0xFF28282D),
      ),
      codeblockDecoration: BoxDecoration(
        color: isUser
            ? Colors.black.withValues(alpha: 0.22)
            : const Color(0xFF0E0E10),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isUser ? Colors.white.withValues(alpha: 0.12) : palette.border,
        ),
      ),
      blockquote: textStyle.copyWith(
        color: isUser
            ? Colors.white.withValues(alpha: 0.9)
            : palette.textSecondary,
        fontSize: 14,
        height: 1.45,
      ),
      blockquotePadding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      blockquoteDecoration: BoxDecoration(
        color: isUser
            ? Colors.black.withValues(alpha: 0.18)
            : palette.surfaceCard,
        borderRadius: BorderRadius.circular(10),
        border: Border(
          left: BorderSide(
            color: isUser
                ? Colors.white38
                : palette.accent.withValues(alpha: 0.55),
            width: 3,
          ),
        ),
      ),
      listBullet: textStyle,
      h1: textStyle.copyWith(fontSize: 18, fontWeight: FontWeight.w700),
      h2: textStyle.copyWith(fontSize: 16, fontWeight: FontWeight.w600),
      h3: textStyle.copyWith(fontSize: 15, fontWeight: FontWeight.w600),
      tableHead: textStyle.copyWith(fontWeight: FontWeight.w700),
      tableBody: textStyle.copyWith(fontSize: 13),
      tableBorder: TableBorder.all(
        color: isUser ? Colors.white.withValues(alpha: 0.25) : palette.border,
        width: 1,
      ),
      tableCellsPadding: const EdgeInsets.symmetric(
        horizontal: 10,
        vertical: 6,
      ),
      tableColumnWidth: const IntrinsicColumnWidth(),
    );
  }
}

class _CodePart {
  final bool isCode;
  final String content;
  final String language;

  const _CodePart({
    required this.isCode,
    required this.content,
    this.language = '',
  });
}

List<_CodePart> _splitCodeBlocks(String text) {
  // Split robusto: fechamento ``` só conta no início da linha.
  // Código com ``` interno (ex.: buf.writeln('```dart')) não quebra o bloco.
  final parts = <_CodePart>[];
  final openRe = RegExp(r'```([^\r\n]*)\r?\n');
  var cursor = 0;
  var i = 0;
  final src = text;

  while (i < src.length) {
    final open = openRe.firstMatch(src.substring(i));
    if (open == null) break;
    final openStart = i + open.start;
    final openEnd = i + open.end;
    final language = (open.group(1) ?? '').trim();

    // markdown antes do fence
    if (openStart > cursor) {
      parts.add(
        _CodePart(isCode: false, content: src.substring(cursor, openStart)),
      );
    }

    // procura fechamento: linha que é só ```
    var closeStart = -1;
    var closeEnd = -1;
    var j = openEnd;
    while (j < src.length) {
      // início de linha
      final lineStart = j;
      var lineEnd = src.indexOf('\n', lineStart);
      if (lineEnd < 0) lineEnd = src.length;
      var line = src.substring(lineStart, lineEnd);
      if (line.endsWith('\r')) {
        line = line.substring(0, line.length - 1);
      }
      if (line.trim() == '```') {
        closeStart = lineStart;
        closeEnd = lineEnd < src.length ? lineEnd + 1 : lineEnd;
        break;
      }
      j = lineEnd < src.length ? lineEnd + 1 : src.length;
    }

    if (closeStart < 0) {
      // fence sem fechamento: trata o resto como código
      var code = src.substring(openEnd);
      if (code.endsWith('\n')) {
        code = code.substring(0, code.length - 1);
      }
      parts.add(_CodePart(isCode: true, content: code, language: language));
      cursor = src.length;
      break;
    }

    var code = src.substring(openEnd, closeStart);
    if (code.endsWith('\r\n')) {
      code = code.substring(0, code.length - 2);
    } else if (code.endsWith('\n')) {
      code = code.substring(0, code.length - 1);
    }
    parts.add(_CodePart(isCode: true, content: code, language: language));
    cursor = closeEnd;
    i = closeEnd;
  }

  if (cursor < src.length) {
    parts.add(_CodePart(isCode: false, content: src.substring(cursor)));
  }

  if (parts.isEmpty) {
    parts.add(_CodePart(isCode: false, content: src));
  }

  return parts;
}

class _CopyableCodeBlock extends StatefulWidget {
  final String code;
  final String language;
  final bool isUser;
  final TextStyle textStyle;

  const _CopyableCodeBlock({
    required this.code,
    required this.language,
    required this.isUser,
    required this.textStyle,
  });

  @override
  State<_CopyableCodeBlock> createState() => _CopyableCodeBlockState();
}

class _CopyableCodeBlockState extends State<_CopyableCodeBlock> {
  bool _copied = false;
  bool _saved = false;
  bool _wrapLines = true;
  bool _expanded = false;

  bool get _isLong =>
      widget.code.length > 2800 || '\n'.allMatches(widget.code).length > 36;

  String get _extension {
    switch (_normalizeCodeLanguage(widget.language)) {
      case 'dart':
        return 'dart';
      case 'python':
        return 'py';
      case 'javascript':
        return 'js';
      case 'typescript':
        return 'ts';
      case 'json':
        return 'json';
      case 'yaml':
        return 'yaml';
      case 'html':
        return 'html';
      case 'css':
        return 'css';
      case 'sql':
        return 'sql';
      case 'bash':
        return 'sh';
      case 'kotlin':
        return 'kt';
      case 'java':
        return 'java';
      case 'c':
        return 'c';
      case 'cpp':
        return 'cpp';
      case 'rust':
        return 'rs';
      case 'go':
        return 'go';
      case 'swift':
        return 'swift';
      default:
        return 'txt';
    }
  }

  Future<void> _copy(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: widget.code));
    await HapticFeedback.lightImpact();
    if (!mounted) return;
    setState(() => _copied = true);
    await Future<void>.delayed(const Duration(milliseconds: 1400));
    if (mounted) setState(() => _copied = false);
  }

  Future<void> _save() async {
    try {
      final stamp = DateTime.now().millisecondsSinceEpoch;
      await DownloadService.instance.saveText(
        widget.code,
        filename: 'gama_codigo_$stamp.$_extension',
      );
      if (!mounted) return;
      setState(() => _saved = true);
      await Future<void>.delayed(const Duration(milliseconds: 1400));
      if (mounted) setState(() => _saved = false);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Não consegui salvar o código: $error')),
      );
    }
  }

  TextSpan _spanForNode(Node node, Map<String, TextStyle> theme) {
    return TextSpan(
      text: node.value,
      style: node.className == null ? null : theme[node.className!],
      children: node.children
          ?.map((child) => _spanForNode(child, theme))
          .toList(),
    );
  }

  TextSpan _highlightedText(Map<String, TextStyle> theme) {
    final base = TextStyle(
      fontFamily: 'monospace',
      fontSize: 13,
      height: 1.55,
      letterSpacing: 0,
      color: theme['root']?.color ?? widget.textStyle.color,
    );
    try {
      final result = highlight.parse(
        widget.code,
        language: _normalizeCodeLanguage(widget.language),
      );
      return TextSpan(
        style: base,
        children: (result.nodes ?? [Node(value: widget.code)])
            .map((node) => _spanForNode(node, theme))
            .toList(),
      );
    } catch (_) {
      return TextSpan(text: widget.code, style: base);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark =
        widget.isUser || Theme.of(context).brightness == Brightness.dark;
    final theme = isDark ? monokaiTheme : githubTheme;
    final background = isDark
        ? const Color(0xFF272822)
        : const Color(0xFFF8F8F8);
    final border = widget.isUser
        ? Colors.white.withValues(alpha: 0.12)
        : context.gama.border;
    final muted = isDark ? const Color(0xFFB8B8B2) : const Color(0xFF666666);
    final highlighted = _highlightedText(theme);
    final content = SelectionArea(
      child: RichText(
        text: highlighted,
        maxLines: _isLong && !_expanded ? 24 : null,
        overflow: _isLong && !_expanded ? TextOverflow.fade : TextOverflow.clip,
        softWrap: _wrapLines,
        textWidthBasis: TextWidthBasis.parent,
      ),
    );

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 48,
            padding: const EdgeInsets.only(left: 12, right: 6),
            decoration: BoxDecoration(
              color: Colors.black.withValues(
                alpha: widget.isUser ? 0.10 : 0.18,
              ),
              border: Border(bottom: BorderSide(color: border)),
            ),
            child: Row(
              children: [
                Icon(Icons.code_rounded, size: 16, color: muted),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    widget.language.isEmpty ? 'Código' : widget.language,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: muted,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: _wrapLines
                      ? 'Desativar quebra de linha'
                      : 'Ativar quebra de linha',
                  constraints: const BoxConstraints.tightFor(
                    width: 48,
                    height: 48,
                  ),
                  onPressed: () => setState(() => _wrapLines = !_wrapLines),
                  icon: Icon(
                    _wrapLines ? Icons.wrap_text_rounded : Icons.notes_rounded,
                    size: 17,
                  ),
                  color: muted,
                ),
                IconButton(
                  tooltip: 'Baixar como arquivo',
                  constraints: const BoxConstraints.tightFor(
                    width: 48,
                    height: 48,
                  ),
                  onPressed: _save,
                  icon: Icon(
                    _saved ? Icons.check_rounded : Icons.download_outlined,
                    size: 18,
                  ),
                  color: _saved ? Colors.green : muted,
                ),
                IconButton(
                  tooltip: _copied ? 'Código copiado' : 'Copiar código',
                  constraints: const BoxConstraints.tightFor(
                    width: 48,
                    height: 48,
                  ),
                  onPressed: () => _copy(context),
                  icon: Icon(
                    _copied ? Icons.check_rounded : Icons.copy_rounded,
                    size: 17,
                  ),
                  color: _copied ? Colors.green : muted,
                ),
              ],
            ),
          ),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 420),
            child: Scrollbar(
              thumbVisibility: true,
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
                child: _wrapLines
                    ? content
                    : SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: content,
                      ),
              ),
            ),
          ),
          if (_isLong && !_expanded)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => setState(() => _expanded = true),
                icon: const Icon(Icons.expand_more_rounded, size: 18),
                label: const Text('Mostrar código completo'),
              ),
            )
          else if (_isLong)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => setState(() => _expanded = false),
                icon: const Icon(Icons.expand_less_rounded, size: 18),
                label: const Text('Recolher código'),
              ),
            ),
        ],
      ),
    );
  }
}

String _normalizeCodeLanguage(String language) {
  final normalized = language.toLowerCase().trim().split(RegExp(r'\s+')).first;
  return switch (normalized) {
    'js' || 'jsx' || 'mjs' || 'cjs' => 'javascript',
    'ts' || 'tsx' => 'typescript',
    'py' || 'python3' => 'python',
    'yml' => 'yaml',
    'sh' || 'shell' || 'zsh' => 'bash',
    'kt' || 'kts' => 'kotlin',
    'c#' || 'cs' => 'csharp',
    'c++' || 'cc' || 'hpp' => 'cpp',
    'md' || 'markdown' => 'markdown',
    '' => 'plaintext',
    _ => normalized,
  };
}

class _HScrollTableBuilder extends MarkdownElementBuilder {
  final bool isUser;
  final void Function(String? href)? onTapLink;

  _HScrollTableBuilder({required this.isUser, required this.onTapLink});

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final color = isUser ? Colors.white : context.gama.textPrimary;
    final rows = <TableRow>[];

    for (final section in element.children ?? <md.Node>[]) {
      if (section is! md.Element) continue;
      final isHead = section.tag == 'thead';

      for (final tr in section.children ?? <md.Node>[]) {
        if (tr is! md.Element || tr.tag != 'tr') continue;

        final cells = <Widget>[];
        for (final cell in tr.children ?? <md.Node>[]) {
          if (cell is! md.Element) continue;
          cells.add(
            Container(
              color: isHead
                  ? (isUser
                        ? Colors.white.withValues(alpha: 0.16)
                        : context.gama.surfaceElevated)
                  : null,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: MarkdownBody(
                data: _inlineMarkdown(cell),
                selectable: true,
                inlineSyntaxes: [_TexMathInlineSyntax()],
                onTapLink: (text, href, title) {
                  if (onTapLink != null) {
                    onTapLink!(href);
                  } else if (href != null) {
                    launchUrl(
                      Uri.parse(href),
                      mode: LaunchMode.externalApplication,
                    );
                  }
                },
                styleSheet: MarkdownStyleSheet(
                  p: TextStyle(
                    color: color,
                    fontSize: 13,
                    height: 1.4,
                    fontWeight: isHead ? FontWeight.w700 : FontWeight.w400,
                  ),
                  a: TextStyle(
                    color: isUser ? Colors.white : context.gama.accent,
                    decoration: TextDecoration.underline,
                  ),
                  code: TextStyle(
                    color: color,
                    fontFamily: 'monospace',
                    backgroundColor: isUser
                        ? Colors.black.withValues(alpha: 0.18)
                        : context.gama.surfaceCard,
                  ),
                ),
                builders: {'math': _TexMathBuilder(TextStyle(color: color, fontSize: 13))},
              ),
            ),
          );
        }
        if (cells.isNotEmpty) rows.add(TableRow(children: cells));
      }
    }

    if (rows.isEmpty) return const SizedBox.shrink();

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Table(
        defaultColumnWidth: const IntrinsicColumnWidth(),
        border: TableBorder.all(
          color: isUser
              ? Colors.white.withValues(alpha: 0.25)
              : context.gama.border,
          width: 1,
        ),
        children: rows,
      ),
    );
  }
}

String _inlineMarkdown(md.Node node) {
  if (node is md.Text) return node.text;
  if (node is! md.Element) return '';
  final inner = (node.children ?? const <md.Node>[])
      .map(_inlineMarkdown)
      .join();
  switch (node.tag) {
    case 'strong':
    case 'b':
      return '**$inner**';
    case 'em':
    case 'i':
      return '*$inner*';
    case 'del':
      return '~~$inner~~';
    case 'code':
      return '`${inner.replaceAll('`', r'\`')}`';
    case 'a':
      final href = node.attributes['href'];
      return href == null ? inner : '[$inner]($href)';
    case 'img':
      final src = node.attributes['src'];
      return src == null ? inner : '![$inner]($src)';
    case 'br':
      return '  \n';
    default:
      return inner;
  }
}

/// Card compacto tipo “chip de arquivo” (estilo moderno).
class _AttachmentChip extends StatelessWidget {
  final AttachmentPreview preview;
  final bool isUser;

  const _AttachmentChip({required this.preview, required this.isUser});

  @override
  Widget build(BuildContext context) {
    final label = preview.kindLabel.toUpperCase();
    final size = _fmtBytes(preview.bytes);
    return Semantics(
      button: true,
      label: 'Pré-visualizar anexo ${preview.name}',
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => showDialog<void>(
            context: context,
            builder: (dialogContext) => AlertDialog(
              backgroundColor: context.gama.surfaceElevated,
              title: Text(preview.name),
              content: SizedBox(
                width: 560,
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        size.isEmpty ? label : '$label • $size',
                        style: TextStyle(color: context.gama.textMuted),
                      ),
                      const SizedBox(height: 12),
                      SelectableText(
                        preview.body.isEmpty
                            ? 'Prévia do anexo indisponível. O arquivo continua anexado à mensagem.'
                            : preview.body,
                        style: TextStyle(
                          color: context.gama.textPrimary,
                          fontFamily:
                              preview.kindLabel.toLowerCase().contains('código')
                              ? 'monospace'
                              : null,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('Fechar'),
                ),
              ],
            ),
          ),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: isUser
                  ? Colors.white.withValues(alpha: 0.10)
                  : context.gama.surfaceCard,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: isUser
                    ? Colors.white.withValues(alpha: 0.12)
                    : context.gama.border,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  _iconForKind(preview.kindLabel),
                  color: isUser ? Colors.white : context.gama.accent,
                  size: 20,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        preview.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: isUser
                              ? Colors.white
                              : context.gama.textPrimary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        size.isEmpty ? label : '$label • $size',
                        style: TextStyle(
                          color: isUser
                              ? Colors.white70
                              : context.gama.textMuted,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  Icons.open_in_full_rounded,
                  color: isUser ? Colors.white70 : context.gama.textMuted,
                  size: 16,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  IconData _iconForKind(String kind) {
    switch (kind.toLowerCase()) {
      case 'zip':
        return Icons.folder_zip_outlined;
      case 'pdf':
        return Icons.picture_as_pdf_outlined;
      case 'imagem':
        return Icons.image_outlined;
      case 'áudio':
      case 'audio':
        return Icons.audiotrack_outlined;
      case 'código':
      case 'codigo':
        return Icons.code_rounded;
      default:
        return Icons.insert_drive_file_outlined;
    }
  }
}
