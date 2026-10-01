import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/gama_colors.dart';

/// Separa texto legível de blocos de anexo extraídos (ZIP/PDF/código).
class ParsedMessage {
  final String text;
  final List<AttachmentPreview> attachments;

  const ParsedMessage({required this.text, required this.attachments});
}

class AttachmentPreview {
  final String name;
  final String kindLabel;
  final String body; // conteúdo extraído (colapsado por padrão)

  const AttachmentPreview({
    required this.name,
    required this.kindLabel,
    required this.body,
  });
}

ParsedMessage parseMessageContent(String content) {
  final raw = content.trim();
  if (raw.isEmpty) {
    return const ParsedMessage(text: '', attachments: []);
  }

  // Marca início da seção de anexos
  final marker = RegExp(r'\n*Anexos para análise:\s*\n?', caseSensitive: false);
  final m = marker.firstMatch(raw);

  String mainText;
  String attachSection;
  if (m != null) {
    mainText = raw.substring(0, m.start).trim();
    attachSection = raw.substring(m.end).trim();
  } else if (raw.startsWith('### ') &&
      (raw.contains('```') || raw.contains('(ZIP)') || raw.contains('(PDF)'))) {
    // mensagem só de anexo
    mainText = '';
    attachSection = raw;
  } else {
    // sem seção explícita: tenta blocos ### nome
    return ParsedMessage(text: raw, attachments: []);
  }

  final attachments = <AttachmentPreview>[];
  // divide por ### headers
  final parts = attachSection.split(RegExp(r'\n(?=### )'));
  for (final part in parts) {
    final t = part.trim();
    if (t.isEmpty) continue;
    final firstLine = t.split('\n').first.replaceFirst(RegExp(r'^###\s*'), '');
    var name = firstLine.trim();
    var kind = 'arquivo';
    if (name.toLowerCase().contains('(zip)')) {
      kind = 'ZIP';
      name = name.replaceAll(RegExp(r'\s*\(ZIP\)', caseSensitive: false), '');
    } else if (name.toLowerCase().contains('(pdf)')) {
      kind = 'PDF';
      name = name.replaceAll(RegExp(r'\s*\(PDF\)', caseSensitive: false), '');
    } else if (name.toLowerCase().contains('imagem')) {
      kind = 'imagem';
    } else if (t.contains('```')) {
      kind = 'código';
    }
    attachments.add(
      AttachmentPreview(
        name: name.isEmpty ? 'Anexo' : name,
        kindLabel: kind,
        body: t,
      ),
    );
  }

  // se não parseou, um card genérico
  if (attachments.isEmpty && attachSection.isNotEmpty) {
    attachments.add(
      AttachmentPreview(
        name: 'Anexo',
        kindLabel: 'arquivo',
        body: attachSection,
      ),
    );
  }

  return ParsedMessage(text: mainText, attachments: attachments);
}

/// Render de mensagem do usuário/assistente com anexos compactos e links ok.
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
              } else {
                _open(href);
              }
            },
            styleSheet: MarkdownStyleSheet(
              p: textStyle,
              a: textStyle.copyWith(
                color: isUser ? Colors.white : GamaColors.accent,
                decoration: TextDecoration.underline,
                decorationColor: (isUser ? Colors.white : GamaColors.accent)
                    .withOpacity(0.7),
              ),
              code: textStyle.copyWith(
                fontFamily: 'monospace',
                fontSize: 13,
                backgroundColor: isUser
                    ? Colors.black26
                    : GamaColors.surfaceInput,
              ),
              codeblockDecoration: BoxDecoration(
                color: isUser ? Colors.black26 : GamaColors.surfaceInput,
                borderRadius: BorderRadius.circular(8),
              ),
              listBullet: textStyle,
              h1: textStyle.copyWith(fontSize: 18, fontWeight: FontWeight.w700),
              h2: textStyle.copyWith(fontSize: 16, fontWeight: FontWeight.w700),
              h3: textStyle.copyWith(fontSize: 15, fontWeight: FontWeight.w600),
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

  /// Transforma URLs soltas em markdown [url](url) sem quebrar layout.
  static String _linkifyBareUrls(String text) {
    // não mexe se já tem markdown link
    final re = RegExp(
      r'''(?<!\]\()(?<!["\'])(https?:\/\/[^\s\)\]\>]+)''',
      caseSensitive: false,
    );
    return text.replaceAllMapped(re, (m) {
      final url = m.group(1)!;
      // evita pontuação final colada
      var clean = url;
      var trailing = '';
      while (clean.isNotEmpty && '.,;:!?'.contains(clean[clean.length - 1])) {
        trailing = clean[clean.length - 1] + trailing;
        clean = clean.substring(0, clean.length - 1);
      }
      return '[$clean]($clean)$trailing';
    });
  }

  static Future<void> _open(String? href) async {
    if (href == null || href.isEmpty) return;
    final uri = Uri.tryParse(href);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
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
    switch (widget.preview.kindLabel.toLowerCase()) {
      case 'zip':
        return Icons.folder_zip_outlined;
      case 'pdf':
        return Icons.picture_as_pdf_outlined;
      case 'código':
      case 'codigo':
        return Icons.code_rounded;
      case 'imagem':
        return Icons.image_outlined;
      default:
        return Icons.insert_drive_file_outlined;
    }
  }

  @override
  Widget build(BuildContext context) {
    final border = widget.isUser
        ? Colors.white.withOpacity(0.25)
        : GamaColors.border;
    final bg = widget.isUser
        ? Colors.black.withOpacity(0.2)
        : GamaColors.surfaceInput;

    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => setState(() => _expanded = !_expanded),
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
                    size: 20,
                    color: widget.isUser ? Colors.white : GamaColors.accent,
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
                            color: widget.isUser
                                ? Colors.white
                                : GamaColors.textPrimary,
                            fontWeight: FontWeight.w600,
                            fontSize: 13.5,
                          ),
                        ),
                        Text(
                          widget.preview.kindLabel,
                          style: TextStyle(
                            color: widget.isUser
                                ? Colors.white70
                                : GamaColors.textMuted,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    _expanded
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    color: widget.isUser
                        ? Colors.white70
                        : GamaColors.textMuted,
                    size: 20,
                  ),
                ],
              ),
              if (_expanded) ...[
                const SizedBox(height: 8),
                Container(
                  constraints: const BoxConstraints(maxHeight: 220),
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
                        color: widget.isUser
                            ? Colors.white70
                            : GamaColors.textSecondary,
                        fontSize: 11.5,
                        fontFamily: 'monospace',
                        height: 1.35,
                      ),
                    ),
                  ),
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: () {
                      Clipboard.setData(
                        ClipboardData(text: widget.preview.body),
                      );
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Conteúdo copiado'),
                          duration: Duration(seconds: 1),
                        ),
                      );
                    },
                    icon: Icon(
                      Icons.copy_rounded,
                      size: 14,
                      color: widget.isUser ? Colors.white70 : GamaColors.accent,
                    ),
                    label: Text(
                      'Copiar',
                      style: TextStyle(
                        fontSize: 12,
                        color: widget.isUser
                            ? Colors.white70
                            : GamaColors.accent,
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
