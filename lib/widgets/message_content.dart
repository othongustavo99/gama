import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:highlight/highlight.dart' show highlight, Node;
import 'package:markdown/markdown.dart' as md;
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/constants.dart';
import '../core/gama_colors.dart';
import '../core/gama_page_route.dart';
import '../screens/oficina_screen.dart';
import '../screens/code_diff_screen.dart';
import '../services/download_service.dart';
import '../utils/error_logger.dart';
import '../utils/friendly_error.dart';
import '../utils/fenced_code.dart';
import '../utils/streaming_text_preview.dart';

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
    : super(
        r'(?<!\\)\$\$([\s\S]+?)\$\$|(?<!\\)\$(?=\S)([^\n$]*?\S)\$(?!\d)|\\\[([\s\S]+?)\\\]|\\\((.+?)\\\)',
      );

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
      ShareParams(files: [XFile(path)], title: 'Imagem da $kAppName'),
    );
  } catch (error, stack) {
    showFriendlyError(
      context.mounted ? context : null,
      error,
      stack,
      acao: 'compartilhar a imagem',
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
                              } catch (error, stack) {
                                showFriendlyError(
                                  context.mounted ? context : null,
                                  error,
                                  stack,
                                  acao: 'salvar a imagem',
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
  final bool standaloneSelection;
  final bool streaming;
  final void Function(String? href)? onTapLink;
  final List<GeneratedImageData> additionalImages;
  final String? referenceCode;
  final String? referenceLanguage;

  const MessageContentView({
    super.key,
    required this.content,
    required this.isUser,
    this.standaloneSelection = true,
    this.streaming = false,
    this.onTapLink,
    this.additionalImages = const [],
    this.referenceCode,
    this.referenceLanguage,
  });

  @override
  Widget build(BuildContext context) {
    if (streaming && !isUser) {
      return _MarkdownMessage(
        text: content,
        isUser: false,
        streaming: true,
        textStyle: TextStyle(
          color: context.gama.textPrimary,
          fontSize: 15,
          height: 1.55,
          letterSpacing: 0.1,
        ),
        onTapLink: onTapLink,
      );
    }
    final extracted = extractGamaImages(content);
    final parsed = isUser
        ? parseMessageContent(extracted.$1)
        : ParsedMessage(
            text: extracted.$1,
            attachments: const [],
            images: extracted.$2,
          );
    final images = [
      ...(isUser ? extracted.$2 : parsed.images),
      ...additionalImages,
    ];

    final textStyle = TextStyle(
      color: isUser ? Colors.white : context.gama.textPrimary,
      fontSize: 15,
      height: 1.55,
      letterSpacing: 0.1,
    );

    Widget buildGeneratedImage(GeneratedImageData img) {
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
                          ? Image.file(File(filePath!), fit: BoxFit.contain)
                          : Image.memory(memoryBytes!, fit: BoxFit.contain),
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
                        padding: const EdgeInsets.symmetric(horizontal: 8),
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
                        } catch (error, stack) {
                          logSwallowed(error, stack);
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text(
                              'Não foi possível salvar ou abrir a imagem. Tente novamente.',
                            )),
                          );
                        }
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
      } catch (error, stack) {
        logSwallowed(error, stack);
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text('Não foi possível exibir esta imagem.',
              style: TextStyle(color: context.gama.textMuted)),
        );
      }
    }

    final body = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (images.isNotEmpty) ...[
            LayoutBuilder(
              builder: (context, constraints) {
                final columns = images.length > 1 && constraints.maxWidth >= 600 ? 2 : 1;
                final itemWidth = columns == 1
                    ? constraints.maxWidth
                    : (constraints.maxWidth - 10) / 2;
                return Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: images
                      .map(
                        (img) => SizedBox(
                          width: itemWidth,
                          child: buildGeneratedImage(img),
                        ),
                      )
                      .toList(growable: false),
                );
              },
            ),
          ],
          if (parsed.text.isNotEmpty)
            _MarkdownMessage(
              text: parsed.text,
              isUser: isUser,
              streaming: streaming,
              referenceCode: referenceCode,
              referenceLanguage: referenceLanguage,
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
    return standaloneSelection ? SelectionArea(child: body) : body;
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
  final bool standaloneSelection;
  final String? referenceCode;
  final String? referenceLanguage;
  final void Function(String? href)? onTapLink;
  final List<GeneratedImageData> additionalImages;

  const MemoizedMessageContentView({
    super.key,
    required this.content,
    required this.isUser,
    this.standaloneSelection = true,
    this.referenceCode,
    this.referenceLanguage,
    this.onTapLink,
    this.additionalImages = const [],
  });

  @override
  State<MemoizedMessageContentView> createState() =>
      _MemoizedMessageContentViewState();
}

bool _sameGeneratedImages(
  List<GeneratedImageData> previous,
  List<GeneratedImageData> next,
) {
  if (identical(previous, next)) return true;
  if (previous.length != next.length) return false;
  for (var i = 0; i < previous.length; i++) {
    if (previous[i].mime != next[i].mime ||
        previous[i].filePath != next[i].filePath ||
        previous[i].base64 != next[i].base64) {
      return false;
    }
  }
  return true;
}

class _MemoizedMessageContentViewState
    extends State<MemoizedMessageContentView> {
  late Widget _cachedContent = _createContent();

  Widget _createContent() => MessageContentView(
    content: widget.content,
    isUser: widget.isUser,
    standaloneSelection: widget.standaloneSelection,
    onTapLink: widget.onTapLink,
    additionalImages: widget.additionalImages,
    referenceCode: widget.referenceCode,
    referenceLanguage: widget.referenceLanguage,
  );

  @override
  void didUpdateWidget(covariant MemoizedMessageContentView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.content != widget.content ||
        oldWidget.isUser != widget.isUser ||
        oldWidget.standaloneSelection != widget.standaloneSelection ||
        oldWidget.referenceCode != widget.referenceCode ||
        oldWidget.referenceLanguage != widget.referenceLanguage ||
        !_sameGeneratedImages(oldWidget.additionalImages, widget.additionalImages)) {
      _cachedContent = _createContent();
    }
  }

  @override
  Widget build(BuildContext context) => _cachedContent;
}

/// Renderiza Markdown normalmente, mas separa blocos cercados por ``` em
/// caixas próprias. Isso permite colocar o botão de copiar sem interferir
/// no restante do Markdown já usado pela Gama.
class _MarkdownMessage extends StatefulWidget {
  final String text;
  final bool isUser;
  final String? referenceCode;
  final String? referenceLanguage;
  final bool streaming;
  final TextStyle textStyle;
  final void Function(String? href)? onTapLink;

  const _MarkdownMessage({
    required this.text,
    required this.isUser,
    required this.streaming,
    this.referenceCode,
    this.referenceLanguage,
    required this.textStyle,
    required this.onTapLink,
  });

  @override
  State<_MarkdownMessage> createState() => _MarkdownMessageState();

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
        color: isUser ? Colors.white : palette.textPrimary,
        backgroundColor: isUser
            ? Colors.black.withValues(alpha: 0.24)
            : palette.surfaceElevated,
      ),
      codeblockDecoration: BoxDecoration(
        color: isUser
            ? Colors.black.withValues(alpha: 0.22)
            : palette.surfaceInput,
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

class _MarkdownMessageState extends State<_MarkdownMessage> {
  final List<_CodePart> _completedParts = [];
  int _parsedLength = 0;

  @override
  void didUpdateWidget(covariant _MarkdownMessage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.streaming ||
        !oldWidget.streaming ||
        !widget.text.startsWith(oldWidget.text)) {
      _completedParts.clear();
      _parsedLength = 0;
    }
  }

  List<_CodePart> _streamingParts() {
    final tail = widget.text.substring(_parsedLength);
    if (tail.isEmpty) return _completedParts;
    final parts = _splitStableParagraphs(
      _splitCodeBlocks(tail, streaming: true),
      tail.length,
    );
    final offset = _parsedLength;
    for (final part in parts) {
      final end = part.endOffset;
      if (end == null) return [..._completedParts, part];
      _completedParts.add(part);
      _parsedLength = offset + end;
    }
    return _completedParts;
  }

  @override
  Widget build(BuildContext context) {
    final parts = widget.streaming
        ? _streamingParts()
        : _splitCodeBlocks(widget.text);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var index = 0; index < parts.length; index++)
          _MarkdownPartView(
            streaming: widget.streaming,
            key: ValueKey('message-part-$index'),
            part: parts[index],
            isUser: widget.isUser,
            referenceCode: widget.referenceCode,
            referenceLanguage: widget.referenceLanguage,
            textStyle: widget.textStyle,
            onTapLink: widget.onTapLink,
          ),
      ],
    );
  }
}

class _MarkdownPartView extends StatefulWidget {
  final bool streaming;
  final _CodePart part;
  final bool isUser;
  final String? referenceCode;
  final String? referenceLanguage;
  final TextStyle textStyle;
  final void Function(String? href)? onTapLink;

  const _MarkdownPartView({
    super.key,
    required this.streaming,
    required this.part,
    required this.isUser,
    this.referenceCode,
    this.referenceLanguage,
    required this.textStyle,
    required this.onTapLink,
  });

  @override
  State<_MarkdownPartView> createState() => _MarkdownPartViewState();
}

class _MarkdownPartViewState extends State<_MarkdownPartView> {
  late Widget _cachedChild;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // MarkdownStyleSheet usa as cores do tema; recrie o cache ao alternar
    // entre claro/escuro ou ao alterar acessibilidade.
    _cachedChild = _buildChild();
  }

  @override
  void didUpdateWidget(covariant _MarkdownPartView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldPart = oldWidget.part;
    final newPart = widget.part;
    if (oldPart.content != newPart.content ||
        oldPart.language != newPart.language ||
        oldPart.isCode != newPart.isCode ||
        oldPart.isOpenCode != newPart.isOpenCode ||
        (oldPart.endOffset == null) != (newPart.endOffset == null) ||
        oldWidget.streaming != widget.streaming ||
        oldWidget.isUser != widget.isUser ||
        oldWidget.textStyle != widget.textStyle ||
        oldWidget.referenceCode != widget.referenceCode ||
        oldWidget.referenceLanguage != widget.referenceLanguage ||
        oldWidget.onTapLink != widget.onTapLink) {
      _cachedChild = _buildChild();
    }
  }

  Widget _buildChild() {
    final part = widget.part;
    if (part.content.trim().isEmpty) return const SizedBox.shrink();
    if (part.isCode) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: RepaintBoundary(
          child: _CopyableCodeBlock(
            key: ValueKey(
              'closed-code-${part.language}-${part.content.hashCode}',
            ),
            code: part.content,
            language: part.language,
            referenceCode: widget.referenceCode,
            referenceLanguage: widget.referenceLanguage,
            isUser: widget.isUser,
            streaming: widget.streaming,
          ),
        ),
      );
    }
    if (part.isOpenCode) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: widget.streaming
            ? _StreamingCodeText(
                code: part.content,
                style: widget.textStyle.copyWith(fontFamily: 'monospace'),
              )
            : SelectableText(
                part.content,
                style: widget.textStyle.copyWith(fontFamily: 'monospace'),
              ),
      );
    }
    if (widget.streaming && part.endOffset == null) {
      return Text(
        streamingTextPreview(part.content),
        style: widget.textStyle,
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: MarkdownBody(
        data: MessageContentView._linkifyBareUrls(part.content),
        // A resposta pode trazer links/imagens parciais. Não permita que
        // o renderer padrão crie imagens gigantes ou decodifique data: URLs.
        imageBuilder: (uri, title, alt) => _BoundedMarkdownImage(
          uri: uri,
          alt: alt,
          streaming: widget.streaming,
        ),
        inlineSyntaxes: [_TexMathInlineSyntax()],
        onTapLink: (linkText, href, title) {
          if (widget.onTapLink != null) {
            widget.onTapLink!(href);
          } else if (href != null) {
            launchUrl(Uri.parse(href), mode: LaunchMode.externalApplication);
          }
        },
        builders: {
          'math': _TexMathBuilder(widget.textStyle),
          'table': _HScrollTableBuilder(
            isUser: widget.isUser,
            onTapLink: widget.onTapLink,
          ),
        },
        styleSheet: _MarkdownMessage._markdownStyleSheet(
          widget.isUser,
          widget.textStyle,
          context.gama,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => _cachedChild;
}

/// Mantém prévias de imagens do Markdown pequenas e previsíveis.
/// Arquivos [gama_image_file] continuam usando o fluxo próprio de imagens.
class _BoundedMarkdownImage extends StatelessWidget {
  final Uri uri;
  final String? alt;
  final bool streaming;

  const _BoundedMarkdownImage({
    required this.uri,
    required this.alt,
    required this.streaming,
  });

  @override
  Widget build(BuildContext context) {
    final isRemote = uri.scheme == 'https' || uri.scheme == 'http';
    final label = (alt ?? '').trim();

    Widget status(String text, {IconData icon = Icons.image_outlined}) =>
        Container(
          height: 92,
          constraints: const BoxConstraints(maxWidth: 340),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: context.gama.surfaceElevated,
            border: Border.all(color: context.gama.borderSoft),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Icon(icon, color: context.gama.accent, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text(text,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: context.gama.textSecondary, fontSize: 12),
                ),
              ),
            ],
          ),
        );

    if (!isRemote) {
      return status('Prévia não disponível para este endereço.');
    }
    if (streaming) {
      return status(label.isEmpty
          ? 'Imagem em preparação…'
          : 'Imagem em preparação: $label');
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 340, maxHeight: 240),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Image.network(
          uri.toString(),
          height: 220,
          fit: BoxFit.contain,
          loadingBuilder: (context, child, progress) => progress == null
              ? child
              : status('Carregando imagem…'),
          errorBuilder: (_, __, ___) =>
              status('Não foi possível carregar a imagem.'),
        ),
      ),
    );
  }
}

class _CodePart {
  final bool isCode;
  final bool isOpenCode;
  final int? endOffset;
  final String content;
  final String language;

  const _CodePart({
    required this.isCode,
    this.isOpenCode = false,
    this.endOffset,
    required this.content,
    this.language = '',
  });
}

// Divide apenas parágrafos fechados e estruturalmente independentes.
// Não fragmenta listas, tabelas, blocos matemáticos, citações, HTML ou links
// por referência: esses dependem do contexto entre linhas no Markdown.
List<_CodePart> _splitStableParagraphs(List<_CodePart> parts, int length) {
  final output = <_CodePart>[];
  final blank = RegExp(r'\r?\n[ \t]*\r?\n');
  final structural = RegExp(
    r'^(?:[ \t]{4}|\t|[ \t]{0,3}(?:[-+*][ \t]+|\d+[.)][ \t]+|>[ \t]?|#{1,6}[ \t]+|~~~|```|---[ \t]*$|\[.+\]:|<))',
    multiLine: true,
  );
  for (final part in parts) {
    if (part.isCode || part.isOpenCode || part.content.isEmpty) {
      output.add(part);
      continue;
    }
    final value = part.content;
    final offset = (part.endOffset ?? length) - value.length;
    var start = 0;
    for (final boundary in blank.allMatches(value)) {
      final segment = value.substring(start, boundary.end);
      // Mantém no mesmo nó qualquer construção potencialmente multilinha.
      if (segment.trim().isEmpty ||
          structural.hasMatch(segment) ||
          segment.contains('|') ||
          segment.contains(r'$$') ||
          segment.contains(r'\[') ||
          segment.contains(r'\]')) {
        continue;
      }
      output.add(_CodePart(
        isCode: false, content: segment, endOffset: offset + boundary.end,
      ));
      start = boundary.end;
    }
    if (start < value.length) {
      output.add(_CodePart(
        isCode: false, content: value.substring(start), endOffset: part.endOffset,
      ));
    }
  }
  return output;
}

List<_CodePart> _splitCodeBlocks(String text, {bool streaming = false}) {
  final parts = <_CodePart>[];
  var cursor = 0;
  for (final block in fencedCodeBlocks(text, streaming: streaming)) {
    if (block.start > cursor) {
      parts.add(_CodePart(
        isCode: false,
        content: text.substring(cursor, block.start),
        endOffset: block.start,
      ));
    }
    parts.add(_CodePart(
      isCode: block.end != null,
      isOpenCode: block.end == null,
      content: block.content(text),
      language: block.language,
      endOffset: block.end,
    ));
    cursor = block.end ?? text.length;
  }
  if (cursor < text.length || parts.isEmpty) {
    parts.add(_CodePart(isCode: false, content: text.substring(cursor)));
  }
  return parts;
}

/// Freeze complete groups of lines so appending tokens only lays out the tail.
class _StreamingCodeText extends StatefulWidget {
  const _StreamingCodeText({required this.code, required this.style});

  final String code;
  final TextStyle style;

  @override
  State<_StreamingCodeText> createState() => _StreamingCodeTextState();
}

class _StreamingCodeTextState extends State<_StreamingCodeText> {
  final _complete = <Widget>[];
  int _tailStart = 0;
  int _scanned = 0;

  @override
  void initState() {
    super.initState();
    _append();
  }

  @override
  void didUpdateWidget(covariant _StreamingCodeText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.style != widget.style || !widget.code.startsWith(oldWidget.code)) {
      _complete.clear();
      _tailStart = 0;
      _scanned = 0;
    }
    _append();
  }

  void _append() {
    var next = widget.code.indexOf('\n', _scanned);
    while (next >= 0) {
      if (next + 1 - _tailStart >= 1600) {
        final end = widget.code.codeUnitAt(next - 1) == 13 ? next - 1 : next;
        _complete.add(Text(widget.code.substring(_tailStart, end), style: widget.style));
        _tailStart = next + 1;
      }
      next = widget.code.indexOf('\n', next + 1);
    }
    _scanned = widget.code.length;
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      ..._complete,
      Text(widget.code.substring(_tailStart), style: widget.style),
    ],
  );
}

class _CopyableCodeBlock extends StatefulWidget {
  final String code;
  final String language;
  final String? referenceCode;
  final String? referenceLanguage;
  final bool isUser;
  final bool fullscreen;
  final bool streaming;

  const _CopyableCodeBlock({
    super.key,
    required this.code,
    required this.language,
    this.referenceCode,
    this.referenceLanguage,
    required this.isUser,
    this.fullscreen = false,
    this.streaming = false,
  });

  @override
  State<_CopyableCodeBlock> createState() => _CopyableCodeBlockState();
}

final _highlightedCodeCache = <(String, String, GamaPalette), TextSpan>{};

class _CopyableCodeBlockState extends State<_CopyableCodeBlock> {
  bool _copied = false;
  bool _wrapLines = true;
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

  Future<void> _copy() async {
    try {
      await Clipboard.setData(ClipboardData(text: widget.code));
    } catch (error, stack) {
      showFriendlyError(
        mounted ? context : null,
        error,
        stack,
        acao: 'copiar o código',
        retry: _copy,
      );
      return;
    }
    if (!mounted) return;
    setState(() => _copied = true);
    unawaited(HapticFeedback.lightImpact().catchError((Object error, StackTrace stack) {
      logSwallowed(error, stack, context: 'confirmar cópia do código');
    }));
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Código salvo')),
      );
    } catch (error, stack) {
      showFriendlyError(
        mounted ? context : null,
        error,
        stack,
        acao: 'salvar o código',
        retry: _save,
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

  TextSpan _highlightedText(GamaPalette palette) {
    final language = _normalizeCodeLanguage(widget.language);
    final cacheKey = (language, widget.code, palette);
    final cached = _highlightedCodeCache[cacheKey];
    if (cached != null) return cached;
    final theme = <String, TextStyle>{
      'comment': TextStyle(color: palette.textMuted, fontStyle: FontStyle.italic),
      'quote': TextStyle(color: palette.textMuted),
      'keyword': TextStyle(color: palette.accentCool, fontWeight: FontWeight.w600),
      'selector-tag': TextStyle(color: palette.accentCool),
      'title': TextStyle(color: palette.accent),
      'function': TextStyle(color: palette.accent),
      'built_in': TextStyle(color: palette.accentCool),
      'type': TextStyle(color: palette.accentCool),
      'string': TextStyle(color: palette.success),
      'number': TextStyle(color: palette.accent),
      'literal': TextStyle(color: palette.accent),
      'attr': TextStyle(color: palette.accent),
      'meta': TextStyle(color: palette.textSecondary),
      'addition': TextStyle(color: palette.success),
      'deletion': TextStyle(color: palette.error),
    };
    final base = TextStyle(
      fontFamily: 'monospace',
      fontSize: 13,
      height: 1.55,
      letterSpacing: 0,
      color: palette.textPrimary,
    );
    try {
      final result = highlight.parse(widget.code, language: language);
      final span = TextSpan(
        style: base,
        children: (result.nodes ?? [Node(value: widget.code)])
            .map((node) => _spanForNode(node, theme))
            .toList(),
      );
      _cacheHighlight(cacheKey, span);
      return span;
    } catch (error, stack) {
      logSwallowed(error, stack);
      final span = TextSpan(text: widget.code, style: base);
      _cacheHighlight(cacheKey, span);
      return span;
    }
  }

  void _cacheHighlight((String, String, GamaPalette) key, TextSpan span) {
    if (_highlightedCodeCache.length >= 80) {
      _highlightedCodeCache.remove(_highlightedCodeCache.keys.first);
    }
    _highlightedCodeCache[key] = span;
  }

  Future<void> _openInOficina() async {
    await HapticFeedback.selectionClick();
    if (!mounted) return;
    await Navigator.of(context).push(
      GamaPageRoute<void>(
        builder: (_) => OficinaScreen(
          initialCode: widget.code,
          initialLanguage: widget.language,
        ),
      ),
    );
  }

  bool get _canCompare {
    final original = widget.referenceCode;
    final referenceLanguage = widget.referenceLanguage?.trim() ?? '';
    return !widget.isUser &&
        original != null &&
        original.trim().isNotEmpty &&
        (referenceLanguage.isEmpty ||
            widget.language.trim().isEmpty ||
            _normalizeCodeLanguage(referenceLanguage) ==
                _normalizeCodeLanguage(widget.language));
  }

  void _openFullscreen() {
    Navigator.of(context).push(GamaPageRoute<void>(
      builder: (_) => _CopyableCodeBlock(
        code: widget.code,
        language: widget.language,
        referenceCode: widget.referenceCode,
        referenceLanguage: widget.referenceLanguage,
        isUser: widget.isUser,
        fullscreen: true,
      ),
    ));
  }

  void _moreAction(String value) {
    switch (value) {
      case 'wrap':
        setState(() => _wrapLines = !_wrapLines);
        return;
      case 'save':
        _save();
        return;
      case 'workshop':
        _openInOficina();
        return;
      case 'compare':
        Navigator.of(context).push(GamaPageRoute<void>(
          builder: (_) => CodeDiffScreen(
            original: widget.referenceCode!,
            proposed: widget.code,
            language: widget.language,
          ),
        ));
        return;
    }
  }

  Widget _copyButton(GamaPalette palette) => IconButton(
    tooltip: _copied ? 'Código copiado' : 'Copiar código',
    onPressed: _copy,
    color: _copied ? palette.success : palette.textSecondary,
    icon: Icon(_copied ? Icons.check_rounded : Icons.copy_rounded, size: 17),
  );

  Widget _menu(GamaPalette palette) => PopupMenuButton<String>(
    tooltip: 'Mais opções do código',
    icon: Icon(Icons.more_vert_rounded, color: palette.textSecondary, size: 19),
    onSelected: _moreAction,
    itemBuilder: (_) => [
      if (widget.fullscreen)
        PopupMenuItem(
          value: 'wrap',
          child: Text(_wrapLines ? 'Desativar quebra de linha' : 'Ativar quebra de linha'),
        ),
      const PopupMenuItem(value: 'save', child: Text('Baixar como arquivo')),
      if (!widget.isUser)
        const PopupMenuItem(value: 'workshop', child: Text('Abrir código na Oficina')),
      if (_canCompare)
        const PopupMenuItem(value: 'compare', child: Text('Comparar com original')),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final palette = context.gama;
    final title = widget.language.isEmpty ? 'Código' : widget.language;
    final content = widget.streaming
        ? _StreamingCodeText(
            code: widget.code,
            style: TextStyle(
              fontFamily: 'monospace',
              color: palette.textPrimary,
              fontSize: 13,
              height: 1.55,
            ),
          )
        : SelectionArea(
            child: RichText(
              text: _highlightedText(palette),
              textScaler: MediaQuery.textScalerOf(context),
              maxLines: widget.fullscreen ? null : 12,
              overflow: widget.fullscreen ? TextOverflow.clip : TextOverflow.fade,
              softWrap: !widget.fullscreen || _wrapLines,
            ),
          );

    if (widget.fullscreen) {
      return Scaffold(
        backgroundColor: palette.surfaceInput,
        appBar: AppBar(
          title: Text(title),
          actions: [_copyButton(palette), _menu(palette)],
        ),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: _wrapLines
                ? content
                : SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: content,
                  ),
          ),
        ),
      );
    }

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: palette.surfaceInput,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: palette.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 40,
            padding: const EdgeInsets.only(left: 12, right: 4),
            color: palette.surfaceElevated,
            child: Row(
              children: [
                Icon(Icons.code_rounded, size: 16, color: palette.textSecondary),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: palette.textSecondary,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                _copyButton(palette),
                _menu(palette),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 2),
            child: content,
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: _openFullscreen,
              icon: const Icon(Icons.open_in_full_rounded, size: 16),
              label: const Text('Expandir'),
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
                builders: {
                  'math': _TexMathBuilder(
                    TextStyle(color: color, fontSize: 13),
                  ),
                },
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
