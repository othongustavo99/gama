import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
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

  // Formato compacto novo:
  // Anexos para análise:
  // ### nome (ZIP)
  // [arquivo:.zip|12345]
  final marker = RegExp(r'\n*Anexos para análise:\s*\n?', caseSensitive: false);
  final m = marker.firstMatch(raw);

  String mainText;
  String section;
  if (m != null) {
    mainText = raw.substring(0, m.start).trim();
    section = raw.substring(m.end).trim();
  } else if (_looksLikeDump(raw)) {
    // legado: ZIP/PDF inteiro na bolha → um card só
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
          body: raw.length > 4000 ? '${raw.substring(0, 4000)}\n…' : raw,
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
    // body só se houver conteúdo real além do meta (legado expandido)
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
      AttachmentPreview(name: 'Anexo', kindLabel: 'arquivo', body: ''),
    );
  }

  return ParsedMessage(text: mainText, attachments: attachments);
}

bool _looksLikeDump(String raw) {
  if (raw.length < 400) return false;
  final codeFences = '```'.allMatches(raw).length;
  if (codeFences >= 2) return true;
  if (raw.contains('(ZIP)') || raw.contains('### ') && raw.length > 800) {
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
      height: 1.45,
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
            styleSheet: MarkdownStyleSheet(
              p: textStyle,
              a: textStyle.copyWith(
                color: isUser ? Colors.white : GamaColors.accent,
                decoration: TextDecoration.underline,
              ),
              code: textStyle.copyWith(fontSize: 13, fontFamily: 'monospace'),
              listBullet: textStyle,
            ),
          ),
        if (parsed.attachments.isNotEmpty) ...[
          if (parsed.text.isNotEmpty) const SizedBox(height: 8),
          ...parsed.attachments.map(
            (a) => Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: _AttachmentCard(preview: a, isUser: isUser),
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

class _AttachmentCard extends StatefulWidget {
  final AttachmentPreview preview;
  final bool isUser;

  const _AttachmentCard({required this.preview, required this.isUser});

  @override
  State<_AttachmentCard> createState() => _AttachmentCardState();
}

class _AttachmentCardState extends State<_AttachmentCard> {
  bool _expanded = false;

  IconData get _icon {
    switch (widget.preview.kindLabel.toUpperCase()) {
      case 'ZIP':
        return Icons.folder_zip_outlined;
      case 'PDF':
        return Icons.picture_as_pdf_outlined;
      case 'IMAGEM':
        return Icons.image_outlined;
      case 'CÓDIGO':
      case 'CODIGO':
        return Icons.code_rounded;
      default:
        return Icons.insert_drive_file_outlined;
    }
  }

  @override
  Widget build(BuildContext context) {
    final isUser = widget.isUser;
    final border = isUser ? Colors.white.withOpacity(0.28) : GamaColors.border;
    final bg = isUser
        ? Colors.black.withOpacity(0.22)
        : GamaColors.surfaceInput;
    final hasBody = widget.preview.body.trim().isNotEmpty;
    final size = _fmtBytes(widget.preview.bytes);

    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: hasBody ? () => setState(() => _expanded = !_expanded) : null,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    _icon,
                    size: 22,
                    color: isUser ? Colors.white : GamaColors.accent,
                  ),
                  const SizedBox(width: 10),
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
                        Text(
                          [
                            widget.preview.kindLabel,
                            if (size.isNotEmpty) size,
                          ].join(' · '),
                          style: TextStyle(
                            color: isUser
                                ? Colors.white70
                                : GamaColors.textMuted,
                            fontSize: 11,
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
                      color: isUser ? Colors.white70 : GamaColors.textMuted,
                    ),
                ],
              ),
              if (_expanded && hasBody) ...[
                const SizedBox(height: 8),
                Container(
                  constraints: const BoxConstraints(maxHeight: 180),
                  width: double.infinity,
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.25),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      widget.preview.body,
                      style: TextStyle(
                        color: isUser
                            ? Colors.white70
                            : GamaColors.textSecondary,
                        fontSize: 11,
                        fontFamily: 'monospace',
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
