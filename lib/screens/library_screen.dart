import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import '../core/constants.dart';
import '../widgets/gama_floating_page.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/gama_colors.dart';
import '../core/responsive_layout.dart';
import '../services/download_service.dart';
import '../services/local_account_scope.dart';
import '../widgets/video_jobs_panel.dart';
import '../widgets/recovery_panel.dart';
import '../widgets/gama_section_intro.dart';
import '../widgets/gama_empty_panel.dart';
import '../widgets/gama_library_image_tile.dart';
import '../widgets/loading_skeleton.dart';
import '../utils/error_logger.dart';
import '../utils/friendly_error.dart';
import '../utils/library_filter.dart';
import '../utils/local_file_metadata.dart';
import '../utils/library_presentation.dart';

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
        final libDir = Directory(p.join(dir.path, LocalAccountScope.current().libraryDirectoryName));
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

    // Metadados de tamanho confiáveis; entradas antigas marcadas com 0 B
    // serão mostradas pelo tamanho real do arquivo quando a Biblioteca abrir.
    final effectiveBytes = savedPath != null && await File(savedPath).exists()
        ? await File(savedPath).length()
        : (sourceBytes?.length ?? bytes);
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(LocalAccountScope.current().libraryPrefsKey) ?? '[]';
    // Nunca substitui uma biblioteca existente se seus metadados estiverem
    // ilegíveis. O conteúdo antigo precisa permanecer recuperável.
    final list = (jsonDecode(raw) as List)
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    list.add({
      'name': name,
      'kind': kind,
      'bytes': effectiveBytes,
      'path': savedPath,
      'at': DateTime.now().toIso8601String(),
      if (conversationId != null) 'conversationId': conversationId,
    });
    // Não descartar os metadados mais antigos (nem deixar arquivos órfãos).
    await prefs.setString(LocalAccountScope.current().libraryPrefsKey, jsonEncode(list));
    return savedPath;
  }

  /// Copia uma imagem ou vídeo da biblioteca para a pasta de downloads do app.
  static Future<void> downloadEntry(
    BuildContext context,
    Map<String, dynamic> it,
  ) async {
    final path = it['path']?.toString();
    final name = it['name']?.toString() ?? 'arquivo';
    if (path == null || path.isEmpty ||
        !await File(path).exists() || await File(path).length() == 0) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Arquivo não encontrado ou vazio.')),
        );
      }
      return;
    }

    try {
      await DownloadService.instance.exportToDownloads(path, filename: name);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Arquivo baixado: $name'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e, stack) {
      showFriendlyError(context.mounted ? context : null, e, stack, acao: 'baixar o arquivo',
        retry: () => downloadEntry(context, it),
      );
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

    if (await file.length() == 0) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Arquivo vazio. Baixe ou gere novamente.')),
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
    } catch (e, stack) {
      showFriendlyError(context.mounted ? context : null, e, stack, acao: 'abrir o arquivo',
        retry: () => openEntry(context, it),
      );
    }
  }

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  final TextEditingController _searchController = TextEditingController();
  List<Map<String, dynamic>> _items = [];
  Map<String, LocalFileMetadata> _fileSnapshots = {};
  int _loadRevision = 0;
  LibraryCategory _category = LibraryCategory.all;
  String _query = '';
  String? _loadError;
  bool _busy = false;
  bool _loading = true;
  bool _selectionMode = false;
  // Índices do snapshot do índice local, evitando colisões entre nomes iguais.
  final Set<int> _selectedKeys = <int>{};
  LibrarySortOrder _sortOrder = LibrarySortOrder.newest;

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
    final revision = ++_loadRevision;
    if (mounted) setState(() => _loading = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(LocalAccountScope.current().libraryPrefsKey) ?? '[]';
      final list = (jsonDecode(raw) as List)
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      final snapshots = await loadLocalFileMetadata(list);
      if (!mounted || revision != _loadRevision) return;
      for (var i = 0; i < list.length; i++) {
        list[i]['_localIndex'] = i; // somente estado de tela, jamais persistido
      }
      setState(() {
        _items = list.reversed.toList();
        _fileSnapshots = snapshots;
        _selectedKeys.clear();
        _selectionMode = false;
        _loadError = null;
      });
    } catch (error, stack) {
      logSwallowed(error, stack);
      if (!mounted || revision != _loadRevision) return;
      setState(() => _loadError =
          'Não foi possível ler o índice da Biblioteca. Seus arquivos não foram apagados.');
    } finally {
      if (mounted && revision == _loadRevision) {
        setState(() => _loading = false);
      }
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
    ++_loadRevision; // invalida carregamentos antigos antes da exclusão
    setState(() => _busy = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      final dir = await getApplicationDocumentsDirectory();
      final libDir = Directory(p.join(dir.path, LocalAccountScope.current().libraryDirectoryName));
      // Confirma primeiro o índice: uma falha ao persistir não pode apagar
      // arquivos que ainda seriam apresentados como disponíveis na lista.
      if (!await prefs.setString(LocalAccountScope.current().libraryPrefsKey, '[]')) {
        throw const FileSystemException('Falha ao atualizar o índice local');
      }
      var cleanupFailed = false;
      try {
        if (await libDir.exists()) await libDir.delete(recursive: true);
      } catch (error, stack) {
        logSwallowed(error, stack, context: 'limpar arquivos da Biblioteca');
        cleanupFailed = true;
      }
      if (mounted) {
        setState(() {
          _items = [];
          _fileSnapshots = {};
          _selectedKeys.clear();
          _selectionMode = false;
        });
        _snack(cleanupFailed
            ? 'Biblioteca esvaziada. Alguns arquivos locais não puderam ser removidos.'
            : 'Biblioteca local esvaziada.');
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
      final all = (jsonDecode(prefs.getString(LocalAccountScope.current().libraryPrefsKey) ?? '[]') as List)
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      final path = entry['path']?.toString();
      bool isSame(Map<String, dynamic> candidate) =>
          candidate['name'] == entry['name'] &&
          candidate['path'] == entry['path'] &&
          candidate['at'] == entry['at'];
      all.removeWhere(isSame);
      if (!await prefs.setString(LocalAccountScope.current().libraryPrefsKey, jsonEncode(all))) {
        throw const FileSystemException('Não foi possível salvar o índice');
      }
      var cleanupFailed = false;
      if (path != null && path.isNotEmpty &&
          !all.any((e) => e['path'] == path)) {
        final root = await getApplicationDocumentsDirectory();
        final ownedDir = p.join(root.path, LocalAccountScope.current().libraryDirectoryName);
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

  void _toggleSelected(Map<String, dynamic> entry) {
    final key = entry['_localIndex'];
    if (key is! int) return;
    setState(() {
      _selectionMode = true;
      if (!_selectedKeys.add(key)) _selectedKeys.remove(key);
    });
  }

  void _cancelSelection() => setState(() {
    _selectionMode = false;
    _selectedKeys.clear();
  });

  /// Exclusão múltipla: atualiza o índice antes de apagar SOMENTE cópias
  /// pertencentes ao diretório privado da Biblioteca. Nunca toca em anexos
  /// originais ou referências ainda usadas por outro registro.
  Future<void> _removeSelected() async {
    if (_busy || _selectedKeys.isEmpty || _loadError != null) return;
    final count = _selectedKeys.length;
    final confirmed = await _confirm(
      title: 'Remover $count ${count == 1 ? 'arquivo' : 'arquivos'}?',
      explanation: 'As cópias locais selecionadas serão removidas. As conversas '
          'e os trabalhos salvos no servidor não serão apagados.',
      action: 'Remover selecionados',
    );
    if (!confirmed || !mounted) return;
    ++_loadRevision;
    setState(() => _busy = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      final all = (jsonDecode(prefs.getString(LocalAccountScope.current().libraryPrefsKey) ?? '[]') as List)
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      // Evita apagar outro item caso a Biblioteca tenha mudado durante a seleção.
      if (all.length != _items.length || all.asMap().entries.any((e) {
        final snapshot = _items[_items.length - 1 - e.key];
        return snapshot['name'] != e.value['name'] ||
            snapshot['path'] != e.value['path'] ||
            snapshot['at'] != e.value['at'];
      })) {
        throw const FormatException('O índice da Biblioteca mudou; atualize antes de remover.');
      }
      final indices = Set<int>.of(_selectedKeys);
      final removed = <Map<String, dynamic>>[];
      final remaining = <Map<String, dynamic>>[];
      for (var i = 0; i < all.length; i++) {
        if (indices.contains(i)) {
          removed.add(all[i]);
        } else {
          remaining.add(all[i]);
        }
      }
      if (!await prefs.setString(LocalAccountScope.current().libraryPrefsKey, jsonEncode(remaining))) {
        throw const FileSystemException('Não foi possível salvar o índice');
      }
      final root = await getApplicationDocumentsDirectory();
      final ownedDir = p.join(root.path, LocalAccountScope.current().libraryDirectoryName);
      var cleanupFailed = false;
      for (final path in removed.map((e) => e['path']?.toString()).whereType<String>().toSet()) {
        if (path.isEmpty || remaining.any((e) => e['path'] == path) || !p.isWithin(ownedDir, path)) continue;
        try {
          final file = File(path);
          if (await file.exists()) await file.delete();
        } catch (error, stack) {
          logSwallowed(error, stack, context: 'remoção múltipla da Biblioteca');
          cleanupFailed = true;
        }
      }
      if (mounted) _cancelSelection();
      await _load();
      _snack(cleanupFailed
          ? 'Registros removidos. Algumas cópias não puderam ser apagadas.'
          : '$count ${count == 1 ? 'arquivo removido' : 'arquivos removidos'} da Biblioteca.');
    } catch (error, stack) {
      logSwallowed(error, stack);
      _snack('Não foi possível remover os arquivos selecionados.');
      await _load();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final filtered = sortLibraryItems(
      filterLibraryItems(_items, category: _category, query: _query),
      order: _sortOrder,
      metadata: _fileSnapshots,
    );
    return Scaffold(
      backgroundColor: context.gama.background,
      
      body: GamaFloatingPage(
        actions: [
          IconButton(
            tooltip: _selectionMode ? 'Cancelar seleção' : 'Selecionar arquivos',
            onPressed: _busy || _loading || _items.isEmpty ? null :
                (_selectionMode ? _cancelSelection : () => setState(() => _selectionMode = true)),
            icon: Icon(_selectionMode ? Icons.close_rounded : Icons.checklist_rounded),
          ),
          IconButton(
            tooltip: 'Atualizar Biblioteca',
            onPressed: _busy || _loading ? null : _load,
            icon: const Icon(Icons.refresh_rounded),
          ),
          if (_items.isNotEmpty && !_selectionMode)
            PopupMenuButton<String>(
              tooltip: 'Mais opções da Biblioteca',
              enabled: !_busy && !_loading && _loadError == null,
              onSelected: (choice) {
                if (choice == 'clear') _clear();
              },
              itemBuilder: (context) => const [
                PopupMenuItem(
                  value: 'clear',
                  child: Row(children: [
                    Icon(Icons.delete_sweep_outlined, size: 18),
                    SizedBox(width: 10),
                    Text('Esvaziar Biblioteca'),
                  ]),
                ),
              ],
              icon: const Icon(Icons.more_horiz_rounded),
            ),
        ],
        child: Column(
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(
              MediaQuery.sizeOf(context).width >= 720 ? 24 : 16,
              14,
              MediaQuery.sizeOf(context).width >= 720 ? 24 : 16,
              6,
            ),
            child: const GamaSectionIntro(
              title: 'Biblioteca',
              description: 'Arquivos locais e tarefas recuperáveis da $kAppName.',
              icon: Icons.folder_open_rounded,
              compact: true,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: ExpansionTile(
                key: const Key('library-activity-section'),
                maintainState: true,
                backgroundColor: context.gama.surfaceCard,
                collapsedBackgroundColor: context.gama.surfaceCard,
                tilePadding: const EdgeInsets.symmetric(horizontal: 14),
                leading: Icon(Icons.cloud_download_outlined, color: context.gama.accent),
                title: const Text('Atividades e recuperações',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                subtitle: Text('Vídeos em andamento e entregas no servidor',
                    style: TextStyle(fontSize: 11, color: context.gama.textMuted)),
                children: [
                  VideoJobsPanel(onLibraryChanged: _load),
                  RecoveryPanel(onLibraryChanged: _load),
                ],
              ),
            ),
          ),
          if (_loadError != null)
            Expanded(
              child: GamaEmptyPanel(
                icon: Icons.error_outline_rounded,
                title: 'Não foi possível carregar a Biblioteca',
                description: _loadError!,
                actionLabel: 'Tentar novamente',
                onAction: _load,
              ),
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
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
              child: Row(
                children: [
                  Expanded(child: Text(
                    _loading ? 'Carregando arquivos…' : _selectionMode
                        ? '${_selectedKeys.length} ${_selectedKeys.length == 1 ? 'selecionado' : 'selecionados'}'
                        : '${filtered.length} ${filtered.length == 1 ? 'arquivo' : 'arquivos'}',
                    style: TextStyle(color: context.gama.textMuted, fontSize: 12),
                  )),
                  if (_selectionMode) ...[
                    TextButton(
                      onPressed: _busy ? null : _cancelSelection,
                      child: const Text('Cancelar'),
                    ),
                    TextButton.icon(
                      onPressed: _busy || _selectedKeys.isEmpty ? null : _removeSelected,
                      icon: const Icon(Icons.delete_outline_rounded, size: 18),
                      label: const Text('Remover'),
                    ),
                  ] else
                    PopupMenuButton<LibrarySortOrder>(
                      key: const Key('library-sort-menu'),
                      tooltip: 'Ordenar arquivos',
                      initialValue: _sortOrder,
                      onSelected: (value) => setState(() => _sortOrder = value),
                      itemBuilder: (_) => [
                        for (final order in LibrarySortOrder.values)
                          PopupMenuItem(value: order, child: Text(order.label)),
                      ],
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Text(_sortOrder.label,
                              style: TextStyle(color: context.gama.textSecondary, fontSize: 12)),
                          const SizedBox(width: 4),
                          Icon(Icons.sort_rounded, size: 18, color: context.gama.textSecondary),
                        ]),
                      ),
                    ),
                ],
              ),
            ),
          ],
          Expanded(
            child: _loadError != null
                ? const SizedBox.shrink()
                : _loading
                    ? (_category == LibraryCategory.images
                        ? const GamaSkeletonGrid(itemCount: 6)
                        : const GamaSkeletonList(itemCount: 5))
                    : RefreshIndicator(
                    onRefresh: _load,
                    child: filtered.isEmpty
                        ? ListView(children: [
                            SizedBox(
                              height: 250,
                              child: GamaEmptyPanel(
                                icon: _items.isEmpty
                                    ? Icons.folder_open_outlined
                                    : Icons.manage_search_rounded,
                                title: _items.isEmpty
                                    ? 'Sua Biblioteca está vazia'
                                    : 'Nenhum arquivo encontrado',
                                description: _items.isEmpty
                                    ? 'Anexe um arquivo na conversa ou crie algo na Oficina. As entregas aparecerão aqui.'
                                    : 'Altere a pesquisa ou escolha outra categoria.',
                              ),
                            ),
                          ])
                        : _category == LibraryCategory.images
                        ? _imageGrid(filtered)
                        : ListView.separated(
                            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                            itemCount: filtered.length,
                            separatorBuilder: (_, __) => const SizedBox(height: 8),
                            itemBuilder: (context, index) {
                              final entry = filtered[index];
                              final kind = entry['kind']?.toString() ?? '';
                              final path = entry['path']?.toString();
                              final metadata = path == null ? null : _fileSnapshots[path];
                              final fileExists = metadata?.exists ?? false;
                              final actualSize = metadata?.bytes ?? 0;
                              final hasFile = fileExists && actualSize > 0;
                              final name = entry['name']?.toString() ?? 'Arquivo';
                              final size = fileExists ? actualSize :
                                  (entry['bytes'] is num ? (entry['bytes'] as num).toInt() : 0);
                              final created = DateTime.tryParse(entry['at']?.toString() ?? '');
                              final date = created == null ? '' :
                                  ' · ${MaterialLocalizations.of(context).formatMediumDate(created.toLocal())}';
                              return Material(
                                color: context.gama.surfaceCard,
                                borderRadius: BorderRadius.circular(14),
                                clipBehavior: Clip.antiAlias,
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(12),
                                  onTap: _selectionMode
                                      ? () => _toggleSelected(entry)
                                      : hasFile
                                          ? () => LibraryScreen.openEntry(context, entry)
                                          : null,
                                  onLongPress: () => _toggleSelected(entry),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12, vertical: 10,
                                    ),
                                    child: Row(
                                      children: [
                                        if (_selectionMode) ...[
                                          Icon(
                                            _selectedKeys.contains(entry['_localIndex'])
                                                ? Icons.check_circle_rounded
                                                : Icons.circle_outlined,
                                            size: 22,
                                            color: _selectedKeys.contains(entry['_localIndex'])
                                                ? context.gama.accent : context.gama.textMuted,
                                          ),
                                          const SizedBox(width: 8),
                                        ],
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
                                                '${hasFile ? date : fileExists ? ' · Arquivo vazio' : ' · Indisponível neste dispositivo'}',
                                                maxLines: 2,
                                                style: TextStyle(
                                                  color: context.gama.textMuted,
                                                  fontSize: 12,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        if (!_selectionMode)
                                          PopupMenuButton<String>(
                                            tooltip: 'Opções de $name',
                                            enabled: !_busy,
                                            onSelected: (action) {
                                              if (action == 'download') {
                                                LibraryScreen.downloadEntry(context, entry);
                                              } else if (action == 'remove') {
                                                _removeOne(entry);
                                              }
                                            },
                                            itemBuilder: (_) => [
                                              if (hasFile)
                                                const PopupMenuItem(value: 'download', child: Text('Baixar')),
                                              const PopupMenuItem(value: 'remove', child: Text('Remover')),
                                            ],
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
      )
      ),
    );
  }

  Widget _imageGrid(List<Map<String, dynamic>> entries) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const gap = 12.0;
        const padding = 16.0;
        final width = (constraints.maxWidth - 2 * padding).clamp(0.0, double.infinity);
        final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
        final columns = GamaGalleryLayout.columns(width, textScale: scale);
        final tileWidth = (width - (columns - 1) * gap) / columns;
        final cacheWidth = (tileWidth * MediaQuery.devicePixelRatioOf(context))
            .round().clamp(180, 900).toInt();
        return GridView.builder(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(padding),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: gap,
            crossAxisSpacing: gap,
            childAspectRatio: .90,
          ),
          itemCount: entries.length,
          itemBuilder: (context, index) {
            final entry = entries[index];
            final name = entry['name']?.toString() ?? 'Imagem';
            final path = entry['path']?.toString();
            final exists = path != null && (_fileSnapshots[path]?.hasContent ?? false);
            return GamaLibraryImageTile(
              name: name,
              path: path,
              available: exists,
              cacheWidth: cacheWidth,
              onOpen: () => LibraryScreen.openEntry(context, entry),
              onDownload: !_busy && exists ? () => LibraryScreen.downloadEntry(context, entry) : null,
              onRemove: _busy ? null : () => _removeOne(entry),
              selectionMode: _selectionMode,
              selected: _selectedKeys.contains(entry['_localIndex']),
              onSelect: () => _toggleSelected(entry),
            );
          },
        );
      },
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
