import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:url_launcher/url_launcher.dart';

import '../core/gama_colors.dart';

class ParsedMessage {
  final String text;
  final List<AttachmentPreview> attachments;

  const ParsedMessage({required this.text, required this.attachments});
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
    final parsed = isUser
        ? parseMessageContent(content)
        : ParsedMessage(text: content, attachments: const []);

    final textStyle = TextStyle(
      color: isUser ? Colors.white : GamaColors.textPrimary,
      fontSize: 15,
      height: 1.5,
      letterSpacing: 0.1,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (parsed.text.isNotEmpty)
          MarkdownBody(
            data: _linkifyBareUrls(parsed.text),
            selectable: false,
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
            builders: {'table': _HScrollTableBuilder(isUser: isUser)},
            styleSheet: MarkdownStyleSheet(
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
              listBullet: textStyle,
              h1: textStyle.copyWith(fontSize: 18, fontWeight: FontWeight.w700),
              h2: textStyle.copyWith(fontSize: 16, fontWeight: FontWeight.w600),
              h3: textStyle.copyWith(fontSize: 15, fontWeight: FontWeight.w600),
              tableHead: textStyle.copyWith(fontWeight: FontWeight.w700),
              tableBody: textStyle.copyWith(fontSize: 13),
              tableBorder: TableBorder.all(
                color: isUser
                    ? Colors.white.withOpacity(0.25)
                    : GamaColors.border,
                width: 1,
              ),
              tableCellsPadding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 6,
              ),
              tableColumnWidth: const IntrinsicColumnWidth(),
            ),
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

/// Renderiza tabelas Markdown com scroll horizontal.
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
class _AttachmentChip extends StatefulWidget {
  final AttachmentPreview preview;
  final bool isUser;

  const _AttachmentChip({required this.preview, required this.isUser});

  @override
  State<_AttachmentChip> createState() => _AttachmentChipState();
}

class _AttachmentChipState extends State<_AttachmentChip> {
  bool _expanded = false;

  IconData get _icon {
    switch (widget.preview.kindLabel.toLowerCase()) {
      case 'zip':
        return Icons.folder_zip_rounded;
      case 'pdf':
        return Icons.picture_as_pdf_rounded;
      case 'imagem':
        return Icons.image_rounded;
      case 'áudio':
      case 'audio':
        return Icons.audiotrack_rounded;
      case 'código':
      case 'codigo':
        return Icons.code_rounded;
      default:
        return Icons.insert_drive_file_rounded;
    }
  }

  Color get _iconBg {
    switch (widget.preview.kindLabel.toLowerCase()) {
      case 'zip':
        return const Color(0xFF3D2E1A);
      case 'pdf':
        return const Color(0xFF3A1F1F);
      case 'imagem':
        return const Color(0xFF1A2E2A);
      case 'código':
      case 'codigo':
        return const Color(0xFF1A2433);
      default:
        return const Color(0xFF252528);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isUser = widget.isUser;
    final hasBody = widget.preview.body.trim().isNotEmpty;
    final size = _fmtBytes(widget.preview.bytes);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: hasBody ? () => setState(() => _expanded = !_expanded) : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: isUser
                ? Colors.black.withOpacity(0.22)
                : GamaColors.surfaceInput,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: isUser
                  ? Colors.white.withOpacity(0.18)
                  : GamaColors.border,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: isUser ? Colors.white.withOpacity(0.12) : _iconBg,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      _icon,
                      size: 20,
                      color: isUser ? Colors.white : GamaColors.accent,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.preview.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: isUser
                                ? Colors.white
                                : GamaColors.textPrimary,
                            fontWeight: FontWeight.w600,
                            fontSize: 13.5,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          [
                            widget.preview.kindLabel.toUpperCase(),
                            if (size.isNotEmpty) size,
                          ].join('  ·  '),
                          style: TextStyle(
                            color: isUser
                                ? Colors.white.withOpacity(0.65)
                                : GamaColors.textMuted,
                            fontSize: 11,
                            letterSpacing: 0.3,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (hasBody)
                    Icon(
                      _expanded
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      color: isUser
                          ? Colors.white.withOpacity(0.7)
                          : GamaColors.textMuted,
                      size: 22,
                    ),
                ],
              ),
              if (_expanded && hasBody) ...[
                const SizedBox(height: 10),
                Container(
                  constraints: const BoxConstraints(maxHeight: 160),
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.28),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      widget.preview.body,
                      style: TextStyle(
                        color: isUser
                            ? Colors.white.withOpacity(0.75)
                            : GamaColors.textSecondary,
                        fontSize: 11,
                        fontFamily: 'monospace',
                        height: 1.35,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
