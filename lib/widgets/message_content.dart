import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;
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
  const GeneratedImageData({required this.mime, required this.base64});
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


final _gamaImageRe = RegExp(
  r'\[gama_image\]\s*mime:([^\n]+)\s*data:([A-Za-z0-9+/=\s]+)\s*\[/gama_image\]',
  multiLine: true,
);

(String, List<GeneratedImageData>) extractGamaImages(String content) {
  final images = <GeneratedImageData>[];
  final text = content.replaceAllMapped(_gamaImageRe, (m) {
    images.add(GeneratedImageData(
      mime: m.group(1)!.trim(),
      base64: m.group(2)!.replaceAll(RegExp(r'\s'), ''),
    ));
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
      color: isUser ? Colors.white : GamaColors.textPrimary,
      fontSize: 15,
      height: 1.55,
      letterSpacing: 0.1,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (images.isNotEmpty) ...[
          ...images.map((img) {
            try {
              final bytes = base64Decode(img.base64);
              return Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(14),
                      child: Image.memory(
                        bytes,
                        fit: BoxFit.cover,
                        gaplessPlayback: true,
                        errorBuilder: (_, __, ___) => const Text(
                          '[imagem indisponível]',
                          style: TextStyle(color: GamaColors.textMuted),
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(
                        style: TextButton.styleFrom(
                          foregroundColor: GamaColors.accent,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          visualDensity: VisualDensity.compact,
                        ),
                        onPressed: () async {
                          try {
                            final path = await DownloadService.instance
                                .saveBase64Image(
                              img.base64,
                              mime: img.mime,
                            );
                            await DownloadService.instance.openPath(path);
                          } catch (_) {}
                        },
                        icon: const Icon(Icons.download_rounded, size: 18),
                        label: const Text('Baixar imagem'),
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
              child: _CopyableCodeBlock(
                code: part.content,
                language: part.language,
                isUser: isUser,
                textStyle: textStyle,
              ),
            )
          else if (part.content.trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: MarkdownBody(
                data: MessageContentView._linkifyBareUrls(part.content),
                selectable: true,
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
                builders: {'table': _HScrollTableBuilder(isUser: isUser)},
                styleSheet: _markdownStyleSheet(isUser, textStyle),
              ),
            ),
      ],
    );
  }

  static MarkdownStyleSheet _markdownStyleSheet(
    bool isUser,
    TextStyle textStyle,
  ) {
    return MarkdownStyleSheet(
      p: textStyle,
      a: textStyle.copyWith(
        color: isUser ? Colors.white : GamaColors.accent,
        decoration: TextDecoration.underline,
        decorationColor: isUser ? Colors.white70 : GamaColors.accent,
      ),
      code: textStyle.copyWith(fontSize: 13, fontFamily: 'monospace'),
      codeblockDecoration: BoxDecoration(
        color: isUser
            ? Colors.black.withOpacity(0.22)
            : const Color(0xFF0E0E10),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isUser
              ? Colors.white.withOpacity(0.12)
              : GamaColors.border,
        ),
      ),
      blockquote: textStyle.copyWith(
        color: isUser
            ? Colors.white.withOpacity(0.9)
            : GamaColors.textSecondary,
        fontSize: 14,
        height: 1.45,
      ),
      blockquotePadding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      blockquoteDecoration: BoxDecoration(
        color: isUser ? Colors.black.withOpacity(0.18) : GamaColors.surfaceCard,
        borderRadius: BorderRadius.circular(10),
        border: Border(
          left: BorderSide(
            color: isUser
                ? Colors.white38
                : GamaColors.accent.withOpacity(0.55),
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
        color: isUser ? Colors.white.withOpacity(0.25) : GamaColors.border,
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
        _CodePart(
          isCode: false,
          content: src.substring(cursor, openStart),
        ),
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
      parts.add(
        _CodePart(isCode: true, content: code, language: language),
      );
      cursor = src.length;
      break;
    }

    var code = src.substring(openEnd, closeStart);
    if (code.endsWith('\r\n')) {
      code = code.substring(0, code.length - 2);
    } else if (code.endsWith('\n')) {
      code = code.substring(0, code.length - 1);
    }
    parts.add(
      _CodePart(isCode: true, content: code, language: language),
    );
    cursor = closeEnd;
    i = closeEnd;
  }

  if (cursor < src.length) {
    parts.add(
      _CodePart(isCode: false, content: src.substring(cursor)),
    );
  }

  if (parts.isEmpty) {
    parts.add(const _CodePart(isCode: false, content: src));
  }

  return parts;
}

class _CopyableCodeBlock extends StatelessWidget {
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

  Future<void> _copy(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: code));
    if (!context.mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Código copiado'),
        duration: Duration(milliseconds: 1200),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final background = isUser
        ? Colors.black.withOpacity(0.22)
        : const Color(0xFF0E0E10);
    final border = isUser
        ? Colors.white.withOpacity(0.12)
        : GamaColors.border;
    final foreground = isUser ? Colors.white : GamaColors.textPrimary;
    final muted = isUser ? Colors.white70 : GamaColors.textMuted;

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
            height: 38,
            padding: const EdgeInsets.only(left: 12, right: 6),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(isUser ? 0.10 : 0.18),
              border: Border(bottom: BorderSide(color: border)),
            ),
            child: Row(
              children: [
                Icon(Icons.code_rounded, size: 16, color: muted),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    language.isEmpty ? 'Código' : language,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: muted,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                TextButton.icon(
                  onPressed: () => _copy(context),
                  style: TextButton.styleFrom(
                    foregroundColor: foreground,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(0, 32),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  icon: const Icon(Icons.copy_rounded, size: 15),
                  label: const Text(
                    'Copiar',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
          // Scroll vertical + horizontal; SelectionArea permite
          // selecionar várias linhas (SelectableText sozinho no
          // scroll horizontal só pegava 1 linha em alguns casos).
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 420),
            child: Scrollbar(
              thumbVisibility: true,
              child: SelectionArea(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: SelectableText(
                      code,
                      style: textStyle.copyWith(
                        color: foreground,
                        fontSize: 13,
                        height: 1.55,
                        fontFamily: 'monospace',
                        letterSpacing: 0,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _HScrollTableBuilder extends MarkdownElementBuilder {
  final bool isUser;

  _HScrollTableBuilder({required this.isUser});

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final color = isUser ? Colors.white : GamaColors.textPrimary;
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
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Text(
                cell.textContent,
                style: TextStyle(
                  color: color,
                  fontSize: 13,
                  height: 1.4,
                  fontWeight: isHead ? FontWeight.w700 : FontWeight.w400,
                ),
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
          color: isUser ? Colors.white.withOpacity(0.25) : GamaColors.border,
          width: 1,
        ),
        children: rows,
      ),
    );
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
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: isUser
            ? Colors.white.withOpacity(0.10)
            : GamaColors.surfaceCard,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isUser
              ? Colors.white.withOpacity(0.12)
              : GamaColors.border,
        ),
      ),
      child: Row(
        children: [
          Icon(
            _iconForKind(preview.kindLabel),
            color: isUser ? Colors.white : GamaColors.accent,
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
                    color: isUser ? Colors.white : GamaColors.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  size.isEmpty ? label : '$label • $size',
                  style: TextStyle(
                    color: isUser ? Colors.white70 : GamaColors.textMuted,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ],
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
