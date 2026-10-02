import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

import 'settings_service.dart';

enum AttachmentKind { text, zip, pdf, image, audio, other }

class ProcessedAttachment {
  final String name;
  final String ext;
  final AttachmentKind kind;

  /// Texto para o corpo da mensagem (docs) ou rótulo curto (imagens).
  final String contentForModel;

  final String label;
  final int bytes;

  /// Imagem nativa: base64 puro (sem data:...). Null se não for imagem.
  final String? imageBase64;
  final String? mimeType;

  ProcessedAttachment({
    required this.name,
    required this.ext,
    required this.kind,
    required this.contentForModel,
    required this.label,
    required this.bytes,
    this.imageBase64,
    this.mimeType,
  });

  bool get isNativeImage =>
      kind == AttachmentKind.image &&
      imageBase64 != null &&
      imageBase64!.isNotEmpty;
}

class AttachmentService {
  static const maxBytesPerFile = 32 * 1024 * 1024; // 32 MB
  static const maxTextExtract = 200000;

  /// Limite para mandar imagem no chat (base64 ~ +33%)
  static const maxImageBytes = 8 * 1024 * 1024; // 8 MB

  static const textExts = {
    '.dart',
    '.py',
    '.js',
    '.ts',
    '.tsx',
    '.jsx',
    '.json',
    '.yaml',
    '.yml',
    '.md',
    '.txt',
    '.html',
    '.css',
    '.xml',
    '.kt',
    '.java',
    '.swift',
    '.go',
    '.rs',
    '.sql',
    '.sh',
    '.c',
    '.cpp',
    '.h',
    '.cs',
    '.rb',
    '.php',
    '.toml',
    '.ini',
    '.cfg',
    '.gradle',
    '.csv',
  };

  static const imageExts = {'.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp'};

  static const audioExts = {'.mp3', '.wav', '.m4a', '.aac', '.ogg', '.flac'};

  static AttachmentKind kindFor(String ext) {
    final e = ext.toLowerCase();
    if (e == '.zip') return AttachmentKind.zip;
    if (e == '.pdf') return AttachmentKind.pdf;
    if (imageExts.contains(e)) return AttachmentKind.image;
    if (audioExts.contains(e)) return AttachmentKind.audio;
    if (textExts.contains(e)) return AttachmentKind.text;
    return AttachmentKind.other;
  }

  static String mimeFor(String ext) {
    switch (ext.toLowerCase()) {
      case '.png':
        return 'image/png';
      case '.gif':
        return 'image/gif';
      case '.webp':
        return 'image/webp';
      case '.bmp':
        return 'image/bmp';
      default:
        return 'image/jpeg';
    }
  }

  Future<ProcessedAttachment> processFile(String path) async {
    final name = p.basename(path);
    final ext = p.extension(path).toLowerCase();
    final file = File(path);
    if (!await file.exists()) {
      throw Exception('Arquivo não encontrado: $name');
    }
    final bytes = await file.length();
    if (bytes > maxBytesPerFile) {
      throw Exception('$name é grande demais (máx. 32 MB)');
    }

    final kind = kindFor(ext);

    switch (kind) {
      case AttachmentKind.text:
        final text = await file.readAsString();
        return ProcessedAttachment(
          name: name,
          ext: ext,
          kind: kind,
          contentForModel: _clip(text),
          label: name,
          bytes: bytes,
        );

      case AttachmentKind.zip:
        final data = await file.readAsBytes();
        return ProcessedAttachment(
          name: name,
          ext: ext,
          kind: kind,
          contentForModel: _extractZipText(data, name),
          label: '$name (ZIP)',
          bytes: bytes,
        );

      case AttachmentKind.pdf:
        final text = await _extractViaApi(path, name);
        return ProcessedAttachment(
          name: name,
          ext: ext,
          kind: kind,
          contentForModel: text,
          label: '$name (PDF)',
          bytes: bytes,
        );

      case AttachmentKind.image:
        // Nativo: NÃO converte em texto via /extract.
        // Manda bytes base64 no chat para o modelo de visão ver a imagem.
        if (bytes > maxImageBytes) {
          throw Exception(
            '$name é grande demais para análise visual (máx. 8 MB). '
            'Tente outra foto ou comprima.',
          );
        }
        final data = await file.readAsBytes();
        final b64 = base64Encode(data);
        final mime = mimeFor(ext);
        return ProcessedAttachment(
          name: name,
          ext: ext,
          kind: kind,
          contentForModel: '', // texto não substitui a imagem
          label: '$name (imagem)',
          bytes: bytes,
          imageBase64: b64,
          mimeType: mime,
        );

      case AttachmentKind.audio:
        return ProcessedAttachment(
          name: name,
          ext: ext,
          kind: kind,
          contentForModel:
              '[Áudio: $name, $bytes bytes]\n'
              'Transcrição automática ainda não está ativa.',
          label: '$name (áudio)',
          bytes: bytes,
        );

      case AttachmentKind.other:
        return ProcessedAttachment(
          name: name,
          ext: ext,
          kind: kind,
          contentForModel: '[Arquivo: $name, $bytes bytes, tipo $ext]',
          label: name,
          bytes: bytes,
        );
    }
  }

  String _clip(String text) {
    final t = text.trim();
    if (t.length <= maxTextExtract) return t;
    return '${t.substring(0, maxTextExtract)}\n\n…[texto cortado]';
  }

  String _extractZipText(List<int> data, String zipName) {
    final archive = ZipDecoder().decodeBytes(data);
    final buf = StringBuffer('### $zipName (ZIP)\n');
    var total = 0;
    var files = 0;

    for (final file in archive) {
      if (!file.isFile) continue;
      final name = file.name;
      if (name.contains('__MACOSX') || name.endsWith('/')) continue;
      final ext = p.extension(name).toLowerCase();
      if (!textExts.contains(ext)) {
        buf.writeln('\n(ignorado binário: $name)');
        continue;
      }
      try {
        var content = utf8.decode(
          file.content as List<int>,
          allowMalformed: true,
        );
        content = _clip(content);
        if (total + content.length > maxTextExtract) {
          buf.writeln('\n…[limite do ZIP]');
          break;
        }
        buf.writeln('\n### $name');
        buf.writeln('```${ext.replaceFirst('.', '')}');
        buf.writeln(content);
        buf.writeln('```');
        total += content.length;
        files++;
      } catch (_) {
        buf.writeln('\n(não leu: $name)');
      }
    }
    if (files == 0) {
      buf.writeln('\nNenhum texto legível no ZIP.');
    }
    return buf.toString();
  }

  Future<String> _extractViaApi(String path, String name) async {
    try {
      final dio = Dio(
        BaseOptions(
          baseUrl: SettingsService.instance.baseUrl,
          connectTimeout: const Duration(seconds: 20),
          receiveTimeout: const Duration(seconds: 120),
        ),
      );
      final form = FormData.fromMap({
        'file': await MultipartFile.fromFile(path, filename: name),
      });
      final res = await dio.post('/extract', data: form);
      final data = res.data as Map<String, dynamic>;
      final text = (data['text'] as String?)?.trim() ?? '';
      if (text.isEmpty) return '[PDF: $name]\nExtração vazia.';
      return text;
    } catch (e) {
      return '[PDF: $name]\nExtração falhou ($e).';
    }
  }

  /// Corpo de texto da mensagem (docs). Imagens vão em `images` no POST /chat.
  static String buildMessageBody(
    String userText,
    List<ProcessedAttachment> attachments,
  ) {
    final textParts = attachments.where((a) => !a.isNativeImage).toList();
    final images = attachments.where((a) => a.isNativeImage).toList();

    if (textParts.isEmpty && images.isEmpty) return userText;

    final buf = StringBuffer();
    if (userText.trim().isNotEmpty) {
      buf.writeln(userText.trim());
    }

    if (images.isNotEmpty) {
      if (buf.isNotEmpty) buf.writeln();
      buf.writeln(
        images.length == 1
            ? 'Analise a imagem anexada (${images.first.name}).'
            : 'Analise as ${images.length} imagens anexadas: '
                  '${images.map((e) => e.name).join(", ")}.',
      );
    }

    for (final a in textParts) {
      buf.writeln();
      if (a.kind == AttachmentKind.text) {
        final lang = a.ext.replaceFirst('.', '');
        buf.writeln('### ${a.name}');
        buf.writeln('```$lang');
        buf.writeln(a.contentForModel);
        buf.writeln('```');
      } else if (a.contentForModel.isNotEmpty) {
        buf.writeln(a.contentForModel);
      }
    }
    return buf.toString().trim();
  }

  /// Texto curto para a bolha do chat (nunca o ZIP/PDF inteiro).
  static String buildDisplayMessage(
    String userText,
    List<ProcessedAttachment> attachments,
  ) {
    final buf = StringBuffer();
    if (userText.trim().isNotEmpty) {
      buf.writeln(userText.trim());
    }
    if (attachments.isEmpty) return buf.toString().trim();

    if (buf.isNotEmpty) buf.writeln();
    buf.writeln('Anexos para análise:');
    for (final a in attachments) {
      String kind = 'arquivo';
      if (a.kind == AttachmentKind.zip)
        kind = 'ZIP';
      else if (a.kind == AttachmentKind.pdf)
        kind = 'PDF';
      else if (a.kind == AttachmentKind.image)
        kind = 'imagem';
      else if (a.kind == AttachmentKind.audio)
        kind = 'áudio';
      else if (a.kind == AttachmentKind.text)
        kind = 'código';
      // só metadados — sem contentForModel
      buf.writeln('### ${a.name} ($kind)');
      buf.writeln('[arquivo:${a.ext}|${a.bytes}]');
    }
    return buf.toString().trim();
  }

  static List<Map<String, String>> buildImagesPayload(
    List<ProcessedAttachment> attachments,
  ) {
    return attachments
        .where((a) => a.isNativeImage)
        .map(
          (a) => {
            'mime': a.mimeType ?? 'image/jpeg',
            'data': a.imageBase64!,
            'name': a.name,
          },
        )
        .toList();
  }
}
