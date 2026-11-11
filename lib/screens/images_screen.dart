import 'dart:convert';

import 'package:flutter/material.dart';
import '../widgets/gama_floating_page.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/local_account_scope.dart';

import '../core/gama_colors.dart';
import '../core/responsive_layout.dart';
import '../utils/error_logger.dart';
import '../utils/library_filter.dart';
import '../utils/local_file_metadata.dart';
import '../utils/library_presentation.dart';
import '../widgets/loading_skeleton.dart';
import '../widgets/gama_section_intro.dart';
import '../widgets/gama_empty_panel.dart';
import '../widgets/gama_library_image_tile.dart';
import 'library_screen.dart';
import 'oficina_screen.dart';
import '../core/gama_page_route.dart';

/// Galeria leve sobre a mesma Biblioteca; não cria cópias adicionais.
class ImagesScreen extends StatefulWidget {
  const ImagesScreen({super.key});

  @override
  State<ImagesScreen> createState() => _ImagesScreenState();
}

class _ImagesScreenState extends State<ImagesScreen> {
  final TextEditingController _search = TextEditingController();
  List<Map<String, dynamic>> _items = [];
  Map<String, LocalFileMetadata> _fileSnapshots = {};
  int _loadRevision = 0;
  String _query = '';
  String? _loadError;
  bool _loading = true;
  LibrarySortOrder _sortOrder = LibrarySortOrder.newest;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
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
      final images = filterLibraryItems(
        list.reversed, category: LibraryCategory.images);
      final snapshots = await loadLocalFileMetadata(images);
      if (!mounted || revision != _loadRevision) return;
      setState(() {
        _items = images;
        _fileSnapshots = snapshots;
        _loadError = null;
      });
    } catch (error, stack) {
      logSwallowed(error, stack);
      if (mounted && revision == _loadRevision) setState(() => _loadError =
          'Não foi possível ler a galeria. Os arquivos continuam preservados.');
    } finally {
      if (mounted && revision == _loadRevision) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final filtered = sortLibraryItems(
      filterLibraryItems(_items, query: _query),
      order: _sortOrder,
      metadata: _fileSnapshots,
    );
    return Scaffold(
      backgroundColor: context.gama.background,
      
      body: GamaFloatingPage(
        actions: [
          IconButton(
            tooltip: 'Abrir Biblioteca',
            onPressed: () async {
              await Navigator.of(context).push(
                GamaPageRoute<void>(builder: (_) => const LibraryScreen()),
              );
              if (mounted) await _load();
            },
            icon: const Icon(Icons.folder_open_outlined),
          ),
          IconButton(
            tooltip: 'Atualizar imagens',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
        child: Column(
              children: [
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    MediaQuery.sizeOf(context).width >= 720 ? 24 : 16,
                    14,
                    MediaQuery.sizeOf(context).width >= 720 ? 24 : 16,
                    0,
                  ),
                  child: const GamaSectionIntro(
                    title: 'Galeria',
                    description: 'Imagens geradas e recebidas em um só lugar.',
                    icon: Icons.collections_outlined,
                    compact: true,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                  child: TextField(
                    controller: _search,
                    onChanged: (value) => setState(() => _query = value),
                    decoration: InputDecoration(
                      hintText: 'Pesquisar imagens',
                      prefixIcon: const Icon(Icons.search_rounded),
                      suffixIcon: _query.isEmpty ? null : IconButton(
                        tooltip: 'Limpar pesquisa',
                        icon: const Icon(Icons.close_rounded),
                        onPressed: () => setState(() {
                          _query = '';
                          _search.clear();
                        }),
                      ),
                      isDense: true,
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                  child: Row(children: [
                    Expanded(child: Text(
                      _loading ? 'Carregando imagens…' :
                          '${filtered.length} ${filtered.length == 1 ? 'imagem' : 'imagens'}',
                      style: TextStyle(color: context.gama.textMuted, fontSize: 12),
                    )),
                    PopupMenuButton<LibrarySortOrder>(
                      key: const Key('gallery-sort-menu'),
                      tooltip: 'Ordenar imagens',
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
                              style: TextStyle(fontSize: 12, color: context.gama.textSecondary)),
                          const SizedBox(width: 4),
                          Icon(Icons.sort_rounded, size: 18, color: context.gama.textSecondary),
                        ]),
                      ),
                    ),
                  ]),
                ),
                Expanded(
                  child: _loading
                      ? const GamaSkeletonGrid(itemCount: 6)
                      : _loadError != null
                          ? GamaEmptyPanel(
                              icon: Icons.error_outline_rounded,
                              title: 'Não foi possível carregar a Galeria',
                              description: _loadError!,
                              actionLabel: 'Tentar novamente',
                              onAction: _load,
                            )
                      : RefreshIndicator(
                          onRefresh: _load,
                          child: filtered.isEmpty
                              ? ListView(children: [
                                  SizedBox(
                                    height: 250,
                                    child: GamaEmptyPanel(
                                      icon: _items.isEmpty
                                          ? Icons.image_outlined
                                          : Icons.manage_search_rounded,
                                      title: _items.isEmpty
                                          ? 'Sua galeria está vazia'
                                          : 'Nenhuma imagem encontrada',
                                      description: _items.isEmpty
                                          ? 'Crie imagens na Oficina ou envie uma imagem na conversa.'
                                          : 'Tente pesquisar com outro nome.',
                                      actionLabel: _items.isEmpty ? 'Abrir Oficina' : 'Limpar pesquisa',
                                      onAction: _items.isEmpty
                                          ? () async {
                                              await Navigator.of(context).push(
                                                GamaPageRoute<void>(builder: (_) => const OficinaScreen()),
                                              );
                                              if (mounted) await _load();
                                            }
                                          : () => setState(() {
                                              _query = '';
                                              _search.clear();
                                            }),
                                    ),
                                  ),
                                ])
                              : LayoutBuilder(builder: (context, constraints) {
                                  const padding = 16.0;
                                  const gap = 12.0;
                                  final usableWidth = (constraints.maxWidth - 2 * padding)
                                      .clamp(0.0, double.infinity);
                                  final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
                                  final columns = GamaGalleryLayout.columns(
                                    usableWidth, textScale: scale);
                                  final tileWidth = (usableWidth - (columns - 1) * gap) / columns;
                                  final thumbPixels = (tileWidth *
                                          MediaQuery.devicePixelRatioOf(context))
                                      .round().clamp(180, 900).toInt();
                                  return GridView.builder(
                                    physics: const AlwaysScrollableScrollPhysics(),
                                    padding: const EdgeInsets.all(16),
                                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                                      crossAxisCount: columns,
                                      mainAxisSpacing: 12,
                                      crossAxisSpacing: 12,
                                      childAspectRatio: 0.9,
                                    ),
                                    itemCount: filtered.length,
                                    itemBuilder: (context, index) {
                                      final it = filtered[index];
                                      final path = it['path']?.toString();
                                      final name = it['name']?.toString() ?? 'Imagem';
                                      final exists = path != null &&
                                          (_fileSnapshots[path]?.hasContent ?? false);
                                      return GamaLibraryImageTile(
                                        name: name,
                                        path: path,
                                        available: exists,
                                        cacheWidth: thumbPixels,
                                        onOpen: () => LibraryScreen.openEntry(context, it),
                                        onDownload: exists
                                            ? () => LibraryScreen.downloadEntry(context, it)
                                            : null,
                                      );
                                    },
                                  );
                                }),
                        ),
                ),
              ],
            )
      ),
    );
  }
}
