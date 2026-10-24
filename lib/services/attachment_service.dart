import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

import '../core/constants.dart';
import 'settings_service.dart';
import 'identity_service.dart';
import 'auth_interceptor.dart';
import '../utils/error_logger.dart';

enum AttachmentKind { text, zip, pdf, document, image, video, audio, other }

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
  final String? sourcePath;
  String? libraryPath;

  ProcessedAttachment({
    required this.name,
    required this.ext,
    required this.kind,
    required this.contentForModel,
    required this.label,
    required this.bytes,
    this.imageBase64,
    this.mimeType,
    this.sourcePath,
  });

  bool get isNativeImage =>
      kind == AttachmentKind.image &&
      imageBase64 != null &&
      imageBase64!.isNotEmpty;
}

class AttachmentService {
  static const maxBytesPerFile = 50 * 1024 * 1024; // documentos/arquivos comuns
  static const maxZipBytes = 200 * 1024 * 1024; // alinhado ao backend (200 MiB)
  static const maxLocalZipFallbackBytes = 50 * 1024 * 1024;
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
  static const videoExts = {'.mp4', '.mov', '.m4v', '.webm', '.mkv'};
  static const maxVideoBytes = 50 * 1024 * 1024;

  static const audioExts = {'.mp3', '.wav', '.m4a', '.aac', '.ogg', '.flac'};

  static AttachmentKind kindFor(String ext) {
    final e = ext.toLowerCase();
    if (e == '.zip') return AttachmentKind.zip;
    if (e == '.pdf') return AttachmentKind.pdf;
    if (e == '.docx') return AttachmentKind.document;
    if (imageExts.contains(e)) return AttachmentKind.image;
    if (videoExts.contains(e)) return AttachmentKind.video;
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
    final kind = kindFor(ext);
    final sizeLimit = kind == AttachmentKind.zip
        ? maxZipBytes
        : kind == AttachmentKind.video
        ? maxVideoBytes
        : maxBytesPerFile;
    if (bytes > sizeLimit) {
      final limitMb = sizeLimit ~/ (1024 * 1024);
      if (kind == AttachmentKind.zip) {
        throw Exception(
          '$name tem ${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB. '
          'O limite deste app é $limitMb MiB por ZIP. Remova .git, venv, '
          'node_modules, build e caches antes de compactar novamente.',
        );
      }
      throw Exception('$name é grande demais (máx. $limitMb MiB)');
    }

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
          sourcePath: path,
        );

      case AttachmentKind.zip:
        // Project Analyzer: envia o caminho para MultipartFile sem carregar o
        // ZIP inteiro na RAM. Isso é especialmente importante para projetos grandes.
        try {
          final summary = await _ingestProjectZip(path, name);
          final id = summary['project_id']?.toString() ?? '';
          if (id.isEmpty) {
            throw Exception(
              'O servidor não retornou o ID do projeto indexado.',
            );
          }
          final plan = summary['review_plan'];
          final preview = plan is Map
              ? 'Prévia de revisão profunda: ${plan['planned_files'] ?? 0} de '
                  '${plan['eligible_files'] ?? 0} arquivos elegíveis planejados; '
                  '${plan['omitted_files'] ?? 0} não selecionados. '
                  'São estimativas de cobertura, não arquivos efetivamente analisados.'
              : '';
          final body =
              '[project_id:$id]\n'
              'Projeto anexado: $name. Use o Code Analyzer com este project_id; '
              'não peça o ZIP de novo. $preview';
          return ProcessedAttachment(
            name: name,
            ext: ext,
            kind: kind,
            contentForModel: body,
            label: name,
            bytes: bytes,
            sourcePath: path,
          );
        } catch (e) {
          // Se o servidor respondeu com erro, não esconda uma rejeição real usando
          // o fallback. Para ZIPs grandes também evitamos uma descompactação local
          // potencialmente pesada; o fallback antigo fica limitado a ZIPs pequenos.
          if (e is DioException && e.response != null) {
            throw Exception(_friendlyProjectUploadError(e, name));
          }
          if (bytes > maxLocalZipFallbackBytes) {
            throw Exception(
              'Não consegui indexar $name no servidor. Como o ZIP é grande, '
              'não vou descompactá-lo localmente para evitar travamentos. '
              'Confira a conexão e o limite de upload do backend e tente novamente. '
              'Detalhe: $e',
            );
          }
          try {
            final data = await file.readAsBytes();
            return ProcessedAttachment(
              name: name,
              ext: ext,
              kind: kind,
              contentForModel: _extractZipText(data, name),
              label: '$name (extração local limitada)',
              bytes: bytes,
              sourcePath: path,
            );
          } catch (fallbackError) {
            throw Exception('Falha ao processar $name: $fallbackError');
          }
        }

      case AttachmentKind.pdf:
      case AttachmentKind.document:
        String text;
        try {
          final summary = await _ingestProjectDocument(path, name, ext);
          final id = summary['project_id']?.toString() ?? '';
          if (id.isEmpty)
            throw Exception('O servidor não retornou o ID do documento.');
          final typeLabel = ext == '.docx' ? 'DOCX' : 'PDF';
          text =
              '[project_id:$id]\n'
              'Documento anexado: $name ($typeLabel). Use o Code Analyzer com este project_id; '
              'não peça o arquivo de novo.';
        } catch (e) {
          // Preserve the existing searchable-text fallback for PDFs. DOCX has
          // no legacy /extract path, so report the indexing failure explicitly.
          text = ext == '.pdf'
              ? await _extractViaApi(path, name)
              : '[DOCX: $name]\nA indexação do documento falhou: $e';
        }
        return ProcessedAttachment(
          name: name,
          ext: ext,
          kind: ext == '.docx' ? AttachmentKind.document : AttachmentKind.pdf,
          contentForModel: text,
          label: '$name (${ext == '.docx' ? 'DOCX' : 'PDF'})',
          bytes: bytes,
          sourcePath: path,
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
          sourcePath: path,
        );

      case AttachmentKind.video:
        try {
          final uploaded = await _uploadVideo(path, name);
          final id = uploaded['artifact_id']?.toString() ?? '';
          if (id.isEmpty)
            throw Exception('O servidor não retornou o ID do vídeo.');
          return ProcessedAttachment(
            name: name,
            ext: ext,
            kind: AttachmentKind.video,
            contentForModel: '[video_artifact_id:$id]\nVídeo anexado: $name.',
            label: '$name (vídeo enviado)',
            bytes: bytes,
            sourcePath: path,
          );
        } catch (e) {
          throw Exception('Não consegui enviar o vídeo $name: $e');
        }

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
          sourcePath: path,
        );

      case AttachmentKind.other:
        return ProcessedAttachment(
          name: name,
          ext: ext,
          kind: kind,
          contentForModel: '[Arquivo: $name, $bytes bytes, tipo $ext]',
          label: name,
          bytes: bytes,
          sourcePath: path,
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
      final name = file.name.replaceAll('\\', '/');
      if (name.endsWith('/') ||
          _isSensitiveArchivePath(name) ||
          _isJunkArchivePath(name))
        continue;
      if (name.startsWith('/') || name.split('/').any((part) => part == '..'))
        continue;
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
      } catch (error, stack) {
        logSwallowed(error, stack);
        buf.writeln('\n(não leu: $name)');
      }
    }
    if (files == 0) {
      buf.writeln('\nNenhum texto legível no ZIP.');
    }
    return buf.toString();
  }

  String _friendlyProjectUploadError(DioException error, String name) {
    final status = error.response?.statusCode;
    final responseData = error.response?.data;
    String detail = '';
    if (responseData is Map) {
      detail = (responseData['detail'] ?? responseData['message'] ?? '')
          .toString();
    } else if (responseData is String) {
      detail = responseData.trim();
    }
    if (status == 413) {
      return '$name foi recusado porque o servidor ou proxy limitou o tamanho '
          'do envio. O app aceita até ${maxZipBytes ~/ (1024 * 1024)} MiB, '
          'mas a hospedagem pode ter um limite menor. Confira MAX_UPLOAD_MB / '
          'MAX_BODY_MB e remova .git, venv, node_modules, build e caches. '
          '${detail.isEmpty ? '' : 'Detalhe: $detail'}';
    }
    if (status == 400 && detail.isNotEmpty) {
      return 'O servidor não aceitou $name: $detail';
    }
    return 'Não foi possível indexar $name no servidor'
        '${status == null ? '' : ' (HTTP $status)'}'
        '${detail.isEmpty ? '' : ': $detail'}';
  }

  bool _isSensitiveArchivePath(String path) {
    final normalized = path.replaceAll('\\', '/').toLowerCase();
    final parts = normalized
        .split('/')
        .where((part) => part.isNotEmpty)
        .toList();
    final name = parts.isEmpty ? '' : parts.last;
    const sensitiveDirs = {
      '.ssh',
      '.aws',
      '.azure',
      '.kube',
      '.gnupg',
      'secrets',
      'private',
    };
    if (parts.take(parts.length - 1).any(sensitiveDirs.contains)) return true;
    if (parts.take(parts.length - 1).contains('.docker') &&
        {'config.json', '.config.json'}.contains(name))
      return true;
    for (var i = 0; i + 1 < parts.length; i++) {
      if (parts[i] == '.config' && parts[i + 1] == 'gcloud') return true;
    }
    const safeTemplates = {
      '.env.example',
      '.env.sample',
      '.env.template',
      '.env.dist',
      'example.env',
      'sample.env',
      'credentials.example.json',
      'service-account.example.json',
      '.npmrc.example',
      '.pypirc.example',
    };
    if (safeTemplates.contains(name)) return false;
    if (name.startsWith('.env.') &&
        (name.endsWith('.example') ||
            name.endsWith('.sample') ||
            name.endsWith('.template') ||
            name.endsWith('.dist'))) {
      return false;
    }
    if (name == '.env' || name.startsWith('.env.')) return true;
    const sensitiveNames = {
      '.npmrc',
      '.pypirc',
      '.netrc',
      '.git-credentials',
      'credentials',
      'credentials.json',
      'secrets',
      'secrets.json',
      'secret.json',
      'token',
      'token.json',
      'tokens.json',
      'auth.json',
      'client_secret.json',
      'service_account.json',
      'service_account_key.json',
      'application_default_credentials.json',
      'id_rsa',
      'id_ed25519',
      'id_ed25519_sk',
      'id_ecdsa',
      'id_dsa',
    };
    if (sensitiveNames.contains(name)) return true;
    const sensitiveSuffixes = {
      '.pem',
      '.key',
      '.p12',
      '.pfx',
      '.jks',
      '.keystore',
      '.mobileprovision',
      '.tfstate',
      '.tfstate.backup',
    };
    if (sensitiveSuffixes.any(name.endsWith)) return true;
    return (name.startsWith('service-account') ||
            name.startsWith('firebase-adminsdk') ||
            name.startsWith('client_secret_')) &&
        name.endsWith('.json');
  }

  bool _isJunkArchivePath(String path) {
    final normalized = path.replaceAll('\\', '/');
    final parts = normalized.split('/');
    const junkDirs = {
      '.git',
      '.svn',
      '.hg',
      '.dart_tool',
      '.idea',
      '.vs',
      '__macosx',
      '__pycache__',
      '.pytest_cache',
      '.mypy_cache',
      '.ruff_cache',
      'node_modules',
      'bower_components',
      'pods',
      'deriveddata',
      'build',
      'dist',
      'out',
      'target',
      '.gradle',
      '.next',
      '.nuxt',
      '.svelte-kit',
      'coverage',
      '.nyc_output',
      'vendor',
      'venv',
      '.venv',
      'env',
    };
    return parts
        .take(parts.length - 1)
        .any((part) => junkDirs.contains(part.toLowerCase()));
  }

  Future<Map<String, dynamic>> _ingestProjectZip(
    String path,
    String name,
  ) async {
    final dio = Dio(
      BaseOptions(
        baseUrl: SettingsService.instance.baseUrl,
        headers: AppConstants.authHeaders,
        connectTimeout: const Duration(seconds: 30),
        sendTimeout: const Duration(minutes: 5),
        receiveTimeout: const Duration(minutes: 5),
      ),
    );
    if (!dio.interceptors.any((i) => i is GammaAuthInterceptor)) {
      dio.interceptors.add(GammaAuthInterceptor(client: dio));
    }
    final form = FormData.fromMap({
      'file': await MultipartFile.fromFile(path, filename: name),
    });
    final res = await dio.post(
      '/project/ingest',
      data: form,
      options: Options(headers: {'X-User-Id': IdentityService.instance.userId}),
    );
    final data = res.data;
    if (data is Map<String, dynamic>) return data;
    return Map<String, dynamic>.from(data as Map);
  }

  Future<Map<String, dynamic>> _uploadVideo(String path, String name) async {
    final dio = Dio(
      BaseOptions(
        baseUrl: SettingsService.instance.baseUrl,
        headers: AppConstants.authHeaders,
        connectTimeout: const Duration(seconds: 30),
        sendTimeout: const Duration(minutes: 3),
        receiveTimeout: const Duration(minutes: 3),
      ),
    );
    if (!dio.interceptors.any((i) => i is GammaAuthInterceptor)) {
      dio.interceptors.add(GammaAuthInterceptor(client: dio));
    }
    final form = FormData.fromMap({
      'file': await MultipartFile.fromFile(path, filename: name),
    });
    final response = await dio.post(
      '/media/videos',
      data: form,
      options: Options(headers: {'X-User-Id': IdentityService.instance.userId}),
    );
    final data = response.data;
    return data is Map<String, dynamic>
        ? data
        : Map<String, dynamic>.from(data as Map);
  }

  Future<Map<String, dynamic>> _ingestProjectDocument(
    String path,
    String name,
    String ext,
  ) async {
    final dio = Dio(
      BaseOptions(
        baseUrl: SettingsService.instance.baseUrl,
        headers: AppConstants.authHeaders,
        connectTimeout: const Duration(seconds: 30),
        receiveTimeout: const Duration(seconds: 180),
      ),
    );
    if (!dio.interceptors.any((i) => i is GammaAuthInterceptor)) {
      dio.interceptors.add(GammaAuthInterceptor(client: dio));
    }
    final form = FormData.fromMap({
      'file': await MultipartFile.fromFile(path, filename: name),
    });
    final route = ext == '.docx'
        ? '/project/ingest/docx'
        : '/project/ingest/pdf';
    final res = await dio.post(
      route,
      data: form,
      options: Options(headers: {'X-User-Id': IdentityService.instance.userId}),
    );
    final data = res.data;
    if (data is Map<String, dynamic>) return data;
    return Map<String, dynamic>.from(data as Map);
  }

  Future<String> _extractViaApi(String path, String name) async {
    try {
      final dio = Dio(
        BaseOptions(
          baseUrl: SettingsService.instance.baseUrl,
          headers: AppConstants.authHeaders,
          connectTimeout: const Duration(seconds: 20),
          receiveTimeout: const Duration(seconds: 120),
        ),
      );
      if (!dio.interceptors.any((i) => i is GammaAuthInterceptor)) {
        dio.interceptors.add(GammaAuthInterceptor(client: dio));
      }
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
      else if (a.kind == AttachmentKind.document)
        kind = 'DOCX';
      else if (a.kind == AttachmentKind.image)
        kind = 'imagem';
      else if (a.kind == AttachmentKind.video)
        kind = 'vídeo';
      else if (a.kind == AttachmentKind.audio)
        kind = 'áudio';
      else if (a.kind == AttachmentKind.text)
        kind = 'código';
      // só metadados — sem contentForModel
      buf.writeln('### ${a.name} ($kind)');
      buf.writeln('[arquivo:${a.ext}|${a.bytes}]');
      // O marcador é pequeno e precisa sobreviver no histórico local para que
      // pedidos posteriores ("altere e me mande em ZIP") encontrem o projeto.
      final projectId = RegExp(r'\[project_id:([A-Za-z0-9_-]{6,128})\]')
          .firstMatch(a.contentForModel);
      if (projectId != null) buf.writeln(projectId.group(0));
      final videoId = RegExp(
        r'\[video_artifact_id:([a-f0-9]{16})\]',
        caseSensitive: false,
      ).firstMatch(a.contentForModel);
      if (videoId != null) buf.writeln(videoId.group(0));
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
