import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

import 'settings_service.dart';

enum AttachmentKind { text, zip, pdf, image, audio, other }

class ProcessedAttachment {
  final String name;
  final String ext;
  final AttachmentKind kind;

  /// Texto que será enviado ao modelo (extraído ou nota descritiva).
  final String contentForModel;

  /// Pré-visualização curta na UI (chip).
  final String label;
  final int bytes;

  ProcessedAttachment({
    required this.name,
    required this.ext,
    required this.kind,
    required this.contentForModel,
    required this.label,
    required this.bytes,
  });
}

/// Processa arquivos locais para anexar no chat.
class AttachmentService {
  static const maxBytesPerFile = 5 * 1024 * 1024; // 5 MB
  static const maxTextExtract = 120000; // ~120k chars no total por arquivo

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
    '.properties',
    '.env',
    '.gitignore',
  };

  static const imageExts = {
    '.png',
    '.jpg',
    '.jpeg',
    '.gif',
    '.webp',
    '.bmp',
    '.heic',
  };

  static const audioExts = {
    '.mp3',
    '.wav',
    '.m4a',
    '.aac',
    '.ogg',
    '.flac',
    '.wma',
  };

  static AttachmentKind kindFor(String ext) {
    final e = ext.toLowerCase();
    if (e == '.zip') return AttachmentKind.zip;
    if (e == '.pdf') return AttachmentKind.pdf;
    if (imageExts.contains(e)) return AttachmentKind.image;
    if (audioExts.contains(e)) return AttachmentKind.audio;
    if (textExts.contains(e)) return AttachmentKind.text;
    return AttachmentKind.other;
  }

  Future<ProcessedAttachment> processFile(String path) async {
    final name = p.basename(path);
    final ext = p.extension(path).toLowerCase();
    final file = File(path);
    final bytes = await file.length();
    if (bytes > maxBytesPerFile) {
      throw Exception('$name é grande demais (máx. 5 MB)');
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
        final extracted = _extractZipText(data, name);
        return ProcessedAttachment(
          name: name,
          ext: ext,
          kind: kind,
          contentForModel: extracted,
          label: '$name (ZIP)',
          bytes: bytes,
        );

      case AttachmentKind.pdf:
        // Tenta API; se falhar, nota descritiva
        final text = await _extractPdfViaApi(path, name);
        return ProcessedAttachment(
          name: name,
          ext: ext,
          kind: kind,
          contentForModel: text,
          label: '$name (PDF)',
          bytes: bytes,
        );

      case AttachmentKind.image:
        return ProcessedAttachment(
          name: name,
          ext: ext,
          kind: kind,
          contentForModel:
              '[Imagem anexada: $name, ${bytes} bytes]\n'
              'O modelo de texto atual não “vê” pixels. '
              'Descreva o que há na imagem ou use um modelo com visão no Ollama (ex.: llava).',
          label: '$name (imagem)',
          bytes: bytes,
        );

      case AttachmentKind.audio:
        return ProcessedAttachment(
          name: name,
          ext: ext,
          kind: kind,
          contentForModel:
              '[Áudio anexado: $name, ${bytes} bytes]\n'
              'Transcrição automática ainda não está ativa neste build. '
              'Cole a transcrição ou o trecho relevante em texto.',
          label: '$name (áudio)',
          bytes: bytes,
        );

      case AttachmentKind.other:
        throw Exception(
          'Tipo $ext não suportado. Use código, ZIP, PDF, imagem ou áudio.',
        );
    }
  }

  String _clip(String text) {
    if (text.length <= maxTextExtract) return text;
    return '${text.substring(0, maxTextExtract)}\n\n…[texto cortado por tamanho]';
  }

  String _extractZipText(Uint8List data, String zipName) {
    final archive = ZipDecoder().decodeBytes(data);
    final buf = StringBuffer();
    buf.writeln('Conteúdo extraído do ZIP: $zipName');
    var total = 0;
    var files = 0;

    for (final file in archive) {
      if (!file.isFile) continue;
      final name = file.name;
      if (name.contains('__MACOSX') || name.endsWith('/')) continue;
      final ext = p.extension(name).toLowerCase();
      if (!textExts.contains(ext) && ext != '.txt' && ext != '.md') {
        buf.writeln('\n(ignorado binário/outro: $name)');
        continue;
      }
      try {
        var content = utf8.decode(
          file.content as List<int>,
          allowMalformed: true,
        );
        content = _clip(content);
        if (total + content.length > maxTextExtract) {
          buf.writeln('\n…[limite de extração do ZIP atingido]');
          break;
        }
        buf.writeln('\n### $name');
        buf.writeln('```${ext.replaceFirst('.', '')}');
        buf.writeln(content);
        buf.writeln('```');
        total += content.length;
        files++;
      } catch (_) {
        buf.writeln('\n(não foi possível ler: $name)');
      }
    }

    if (files == 0) {
      buf.writeln('\nNenhum arquivo de texto legível encontrado no ZIP.');
    }
    return buf.toString();
  }

  Future<String> _extractPdfViaApi(String path, String name) async {
    try {
      final dio = Dio(
        BaseOptions(
          baseUrl: SettingsService.instance.baseUrl,
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 60),
        ),
      );
      final form = FormData.fromMap({
        'file': await MultipartFile.fromFile(path, filename: name),
      });
      final res = await dio.post('/extract', data: form);
      final data = res.data as Map<String, dynamic>;
      final text = (data['text'] as String?)?.trim() ?? '';
      if (text.isEmpty) {
        return '[PDF: $name]\nNão foi possível extrair texto (PDF escaneado ou vazio).';
      }
      return '### $name (PDF)\n\n${_clip(text)}';
    } catch (e) {
      return '[PDF anexado: $name]\n'
          'Extração via API falhou ($e). '
          'Suba a Frequência40 API com suporte a /extract (pypdf) ou cole o texto do PDF.';
    }
  }

  /// Monta o bloco final para a mensagem do usuário.
  static String buildMessageBody(
    String userText,
    List<ProcessedAttachment> attachments,
  ) {
    if (attachments.isEmpty) return userText;

    final buf = StringBuffer();
    if (userText.trim().isNotEmpty) {
      buf.writeln(userText.trim());
      buf.writeln();
    }
    buf.writeln('Anexos para análise:');
    for (final a in attachments) {
      buf.writeln();
      if (a.kind == AttachmentKind.text) {
        final lang = a.ext.replaceFirst('.', '');
        buf.writeln('### ${a.name}');
        buf.writeln('```$lang');
        buf.writeln(a.contentForModel);
        buf.writeln('```');
      } else {
        buf.writeln(a.contentForModel);
      }
    }
    return buf.toString();
  }
}
