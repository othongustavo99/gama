import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/gama_colors.dart';
import '../services/download_service.dart';
import '../widgets/video_jobs_panel.dart';
import '../utils/error_logger.dart';
import '../utils/library_filter.dart';

/// Biblioteca local de anexos (metadados + arquivo persistido).
class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  /// Copia o arquivo para pasta permanente e registra na biblioteca.
  static Future<String?> addEntry({
    required String name,
    required String kind,
    required int bytes,
    String? conversationId,
    String? sourcePath,
    Uint8List? sourceBytes,
  }) async {
    String? savedPath;
    if ((sourcePath != null && sourcePath.isNotEmpty) || sourceBytes != null) {
      try {
        final dir = await getApplicationDocumentsDirectory();
        final libDir = Directory(p.join(dir.path, 'gama_library'));
        if (!await libDir.exists()) {
          await libDir.create(recursive: true);
        }
        final safe = name.replaceAll(RegExp(r'[^\w\.\-]+'), '_');
        final dest = p.join(
          libDir.path,
          '${DateTime.now().microsecondsSinceEpoch}_$safe',
        );
        if (sourceBytes != null) {
          await File(dest).writeAsBytes(sourceBytes, flush: true);
          savedPath = dest;
        } else {
          final src = File(sourcePath!);
          if (await src.exists()) {
            await src.copy(dest);
            savedPath = dest;
          }
        }
      } catch (error, stack) {
        logSwallowed(error, stack);
        savedPath = null;
      }
    }

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('gama_library') ?? '[]';
    // Nunca substitui uma biblioteca existente se seus metadados estiverem
    // ilegíveis. O conteúdo antigo precisa permanecer recuperável.
    final list = (jsonDecode(raw) as List)
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    list.add({
      'name': name,
      'kind': kind,
      'bytes': bytes,
      'path': savedPath,
      'at': DateTime.now().toIso8601String(),
      if (conversationId != null) 'conversationId': conversationId,
    });
    // Não descartar os metadados mais antigos (nem deixar arquivos órfãos).
    await prefs.setString('gama_library', jsonEncode(list));
    return savedPath;
  }

  /// Copia uma imagem ou vídeo da biblioteca para a pasta de downloads do app.
  static Future<void> downloadEntry(
    BuildContext context,
    Map<String, dynamic> it,
  ) async {
    final path = it['path']?.toString();
    final name = it['name']?.toString() ?? 'arquivo';
    if (path == null || path.isEmpty || !await File(path).exists()) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Arquivo não encontrado no disco.')),
        );
      }
      return;
    }

    try {
      await DownloadService.instance.copyFile(path, filename: name);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Arquivo baixado: $name'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Não consegui baixar o arquivo: $e')),
        );
      }
    }
  }

  /// Abre arquivo/imagem da biblioteca (foto no app; PDF/ZIP no visualizador do SO).
  static Future<void> openEntry(
    BuildContext context,
    Map<String, dynamic> it,
  ) async {
    final path = it['path']?.toString();
    final name = it['name']?.toString() ?? 'arquivo';
    final kind = (it['kind']?.toString() ?? '').toLowerCase();

    if (path == null || path.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Arquivo sem caminho salvo. Anexe de novo para poder abrir.',
            ),
          ),
        );
      }
      return;
    }

    final file = File(path);
    if (!await file.exists()) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Arquivo não encontrado no disco.')),
        );
      }
      return;
    }

    final isImage =
        kind == 'image' ||
        path.toLowerCase().endsWith('.png') ||
        path.toLowerCase().endsWith('.jpg') ||
        path.toLowerCase().endsWith('.jpeg') ||
        path.toLowerCase().endsWith('.gif') ||
        path.toLowerCase().endsWith('.webp') ||
        path.toLowerCase().endsWith('.bmp');

    if (isImage) {
      if (!context.mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => Dialog(
          backgroundColor: context.gama.surface,
          insetPadding: const EdgeInsets.all(12),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(ctx).size.width * 0.95,
              maxHeight: MediaQuery.of(ctx).size.height * 0.85,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          name,
                          style: TextStyle(
                            color: context.gama.textPrimary,
                            fontWeight: FontWeight.w600,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      IconButton(
                        icon: Icon(Icons.close, color: context.gama.textMuted),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                    ],
                  ),
                ),
                Flexible(
                  child: InteractiveViewer(
                    minScale: 0.5,
                    maxScale: 4,
                    child: Image.file(
                      file,
                      fit: BoxFit.contain,
                      errorBuilder: (_, __, ___) => Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                          'Não foi possível carregar a imagem',
                          style: TextStyle(color: context.gama.textMuted),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
              ],
            ),
          ),
        ),
      );
      return;
    }

    // PDF, ZIP, código, áudio → seletor nativo / Explorer.
    try {
      await DownloadService.instance.openGeneratedFile(path);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Erro ao abrir: $e')));
      }
    }
  }

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  final TextEditingController _searchController = TextEditingController();
  List<Map<String, dynamic>> _items = [];
  LibraryCategory _category = LibraryCategory.all;
  String _query = '';
  String? _loadError;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('gama_library') ?? '[]';
      final list = (jsonDecode(raw) as List)
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      if (!mounted) return;
      setState(() {
        _items = list.reversed.toList();
        _loadError = null;
      });
    } catch (error, stack) {
      logSwallowed(error, stack);
      if (!mounted) return;
      setState(() => _loadError =
          'Não foi possível ler o índice da Biblioteca. Seus arquivos não foram apagados.');
    }
  }

  void _snack(String text) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(content: Text(text)));
  }

  Future<bool> _confirm({
    required String title,
    required String explanation,
    required String action,
  }) async {
    return await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(title),
            content: Text(explanation),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancelar'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                style: TextButton.styleFrom(foregroundColor: ctx.gama.error),
                child: Text(action),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _clear() async {
    if (_busy || _items.isEmpty || _loadError != null) return;
    final confirmed = await _confirm(
      title: 'Esvaziar a Biblioteca?',
      explanation: 'Os arquivos locais registrados na Biblioteca serão apagados '
          'do dispositivo. Suas conversas e os trabalhos armazenados no Railway '
          'não serão apagados. Esta ação não pode ser desfeita.',
      action: 'Esvaziar Biblioteca',
    );
    if (!confirmed || !mounted) return;
    setState(() => _busy = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      final dir = await getApplicationDocumentsDirectory();
      final libDir = Directory(p.join(dir.path, 'gama_library'));
      if (await libDir.exists()) await libDir.delete(recursive: true);
      if (!await prefs.setString('gama_library', '[]')) {
        throw const FileSystemException('Falha ao atualizar o índice local');
      }
      if (mounted) {
        setState(() => _items = []);
        _snack('Biblioteca local esvaziada.');
      }
    } catch (error, stack) {
      logSwallowed(error, stack);
      _snack('Não foi possível esvaziar a Biblioteca. Os metadados foram preservados quando possível.');
      await _load();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _removeOne(Map<String, dynamic> entry) async {
    if (_busy || _loadError != null) return;
    final name = (entry['name'] ?? 'arquivo').toString();
    if (!await _confirm(
      title: 'Remover da Biblioteca?',
      explanation: 'Remover “$name” da Biblioteca e excluir sua cópia local? '
          'A conversa de origem não será apagada.',
      action: 'Remover',
    )) return;
    if (!mounted) return;
    setState(() => _busy = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      final all = (jsonDecode(prefs.getString('gama_library') ?? '[]') as List)
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      final path = entry['path']?.toString();
      bool isSame(Map<String, dynamic> candidate) =>
          candidate['name'] == entry['name'] &&
          candidate['path'] == entry['path'] &&
          candidate['at'] == entry['at'];
      all.removeWhere(isSame);
      if (!await prefs.setString('gama_library', jsonEncode(all))) {
        throw const FileSystemException('Não foi possível salvar o índice');
      }
      var cleanupFailed = false;
      if (path != null && path.isNotEmpty &&
          !all.any((e) => e['path'] == path)) {
        final root = await getApplicationDocumentsDirectory();
        final ownedDir = p.join(root.path, 'gama_library');
        // Nunca apagar diretamente arquivos anexados fora da pasta da Gamma.
        if (p.isWithin(ownedDir, path)) {
          try {
            final copy = File(path);
            if (await copy.exists()) await copy.delete();
          } catch (error, stack) {
            logSwallowed(error, stack);
            cleanupFailed = true;
          }
        }
      }
      await _load();
      _snack(cleanupFailed
          ? 'Item removido, mas não consegui excluir a cópia do disco.'
          : 'Item removido da Biblioteca.');
    } catch (error, stack) {
      logSwallowed(error, stack);
      _snack('Não foi possível remover o item. Tente novamente.');
      await _load();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final filtered = filterLibraryItems(
      _items,
      category: _category,
      query: _query,
    );
    return Scaffold(
      backgroundColor: context.gama.background,
      appBar: AppBar(
        backgroundColor: context.gama.surface,
        title: const Text('Biblioteca'),
        actions: [
          IconButton(
            tooltip: 'Atualizar Biblioteca',
            onPressed: _busy ? null : _load,
            icon: const Icon(Icons.refresh_rounded),
          ),
          if (_items.isNotEmpty)
            IconButton(
              tooltip: 'Esvaziar Biblioteca',
              onPressed: _busy || _loadError != null ? null : _clear,
              icon: Icon(Icons.delete_sweep_outlined, color: context.gama.error),
            ),
        ],
      ),
      body: Column(
        children: [
          VideoJobsPanel(onLibraryChanged: _load),
          if (_loadError != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(_loadError!,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: context.gama.error)),
            ),
          if (_loadError == null) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: TextField(
                controller: _searchController,
                onChanged: (value) => setState(() => _query = value),
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: 'Buscar arquivos pelo nome',
                  prefixIcon: const Icon(Icons.search_rounded),
                  suffixIcon: _query.isEmpty ? null : IconButton(
                    tooltip: 'Limpar pesquisa',
                    onPressed: () => setState(() {
                      _query = '';
                      _searchController.clear();
                    }),
                    icon: const Icon(Icons.close_rounded),
                  ),
                  isDense: true,
                ),
              ),
            ),
            SizedBox(
              height: 48,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                children: [
                  for (final category in LibraryCategory.values)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: FilterChip(
                        selected: _category == category,
                        label: Text(category.label),
                        onSelected: (_) => setState(() => _category = category),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '${filtered.length} ${filtered.length == 1 ? 'arquivo' : 'arquivos'}',
                  style: TextStyle(color: context.gama.textMuted, fontSize: 12),
                ),
              ),
            ),
          ],
          Expanded(
            child: _loadError != null
                ? const SizedBox.shrink()
                : RefreshIndicator(
                    onRefresh: _load,
                    child: filtered.isEmpty
                        ? ListView(children: [
                            SizedBox(
                              height: 220,
                              child: Center(
                                child: Padding(
                                  padding: const EdgeInsets.all(24),
                                  child: Text(
                                    _items.isEmpty
                                        ? 'Sua Biblioteca está vazia.\nAnexe arquivos no chat ou crie algo na Oficina.'
                                        : 'Nenhum arquivo corresponde à busca ou filtro.',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(color: context.gama.textMuted),
                                  ),
                                ),
                              ),
                            ),
                          ])
                        : ListView.separated(
                            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                            itemCount: filtered.length,
                            separatorBuilder: (_, __) => const SizedBox(height: 8),
                            itemBuilder: (context, index) {
                              final entry = filtered[index];
                              final kind = entry['kind']?.toString() ?? '';
                              final path = entry['path']?.toString();
                              final hasFile = path != null &&
                                  path.isNotEmpty && File(path).existsSync();
                              final name = entry['name']?.toString() ?? 'Arquivo';
                              final size = entry['bytes'] is num
                                  ? (entry['bytes'] as num).toInt() : 0;
                              return Material(
                                color: context.gama.surfaceCard,
                                borderRadius: BorderRadius.circular(12),
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(12),
                                  onTap: hasFile
                                      ? () => LibraryScreen.openEntry(context, entry)
                                      : null,
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12, vertical: 10,
                                    ),
                                    child: Row(
                                      children: [
                                        Icon(_icon(kind),
                                            color: hasFile
                                                ? context.gama.accent
                                                : context.gama.textMuted,
                                            size: 23),
                                        const SizedBox(width: 12),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Text(name,
                                                  maxLines: 2,
                                                  overflow: TextOverflow.ellipsis,
                                                  style: TextStyle(
                                                    color: context.gama.textPrimary,
                                                    fontWeight: FontWeight.w600,
                                                  )),
                                              const SizedBox(height: 3),
                                              Text(
                                                '${categoryForLibraryItem(entry).label} · ${_fmtBytes(size)}'
                                                '${hasFile ? '' : ' · Indisponível neste dispositivo'}',
                                                maxLines: 2,
                                                style: TextStyle(
                                                  color: context.gama.textMuted,
                                                  fontSize: 12,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        if (hasFile)
                                          IconButton(
                                            tooltip: 'Salvar $name nos downloads',
                                            onPressed: _busy ? null : () =>
                                                LibraryScreen.downloadEntry(context, entry),
                                            icon: const Icon(Icons.download_outlined),
                                          ),
                                        IconButton(
                                          tooltip: 'Remover $name da Biblioteca',
                                          onPressed: _busy ? null : () => _removeOne(entry),
                                          icon: Icon(Icons.delete_outline_rounded,
                                              color: context.gama.textMuted),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
          ),
        ],
      ),
    );
  }

  IconData _icon(String kind) {
    switch (kind) {
      case 'pdf':
        return Icons.picture_as_pdf_outlined;
      case 'zip':
        return Icons.folder_zip_outlined;
      case 'image':
        return Icons.image_outlined;
      case 'audio':
        return Icons.audiotrack_outlined;
      case 'video':
        return Icons.movie_outlined;
      default:
        return Icons.insert_drive_file_outlined;
    }
  }

  String _fmtBytes(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
