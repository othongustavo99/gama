import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import '../widgets/gama_floating_page.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/local_account_scope.dart';

import '../core/gama_colors.dart';
import '../utils/error_logger.dart';
import '../utils/library_filter.dart';
import '../widgets/loading_skeleton.dart';
import '../widgets/gama_section_intro.dart';
import '../widgets/gama_empty_panel.dart';
import 'library_screen.dart';

/// Galeria leve sobre a mesma Biblioteca; não cria cópias adicionais.
class ImagesScreen extends StatefulWidget {
  const ImagesScreen({super.key});

  @override
  State<ImagesScreen> createState() => _ImagesScreenState();
}

class _ImagesScreenState extends State<ImagesScreen> {
  final TextEditingController _search = TextEditingController();
  List<Map<String, dynamic>> _items = [];
  String _query = '';
  String? _loadError;
  bool _loading = true;

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
    if (mounted) setState(() => _loading = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(LocalAccountScope.current().libraryPrefsKey) ?? '[]';
      final list = (jsonDecode(raw) as List)
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      if (!mounted) return;
      setState(() {
        _items = filterLibraryItems(list.reversed,
            category: LibraryCategory.images);
        _loadError = null;
      });
    } catch (error, stack) {
      logSwallowed(error, stack);
      if (mounted) setState(() => _loadError =
          'Não foi possível ler a galeria. Os arquivos continuam preservados.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final filtered = filterLibraryItems(_items, query: _query);
    return Scaffold(
      backgroundColor: context.gama.background,
      
      body: GamaFloatingPage(
        actions: [
          IconButton(
            tooltip: 'Atualizar imagens',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
        child: _loading
          ? const GamaSkeletonGrid(itemCount: 6)
          : Column(
              children: [
                if (MediaQuery.sizeOf(context).width >= 720)
                  const Padding(
                    padding: EdgeInsets.fromLTRB(24, 16, 24, 0),
                    child: GamaSectionIntro(
                      title: 'Galeria',
                      description: 'Suas imagens geradas e recebidas em um só lugar.',
                      icon: Icons.collections_outlined,
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
                Expanded(
                  child: _loadError != null
                      ? Center(child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(_loadError!,
                              textAlign: TextAlign.center,
                              style: TextStyle(color: context.gama.error)),
                        ))
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
                                    ),
                                  ),
                                ])
                              : LayoutBuilder(builder: (context, constraints) {
                                  final columns = (constraints.maxWidth / 190)
                                      .floor().clamp(2, 6).toInt();
                                  final thumbPixels = (constraints.maxWidth /
                                          columns *
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
                                          path.isNotEmpty && File(path).existsSync();
                                      return Material(
                                        color: context.gama.surfaceCard,
                                        borderRadius: BorderRadius.circular(14),
                                        child: InkWell(
                                          borderRadius: BorderRadius.circular(14),
                                          onTap: exists
                                              ? () => LibraryScreen.openEntry(context, it)
                                              : null,
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.stretch,
                                            children: [
                                              Expanded(child: Stack(
                                                fit: StackFit.expand,
                                                children: [
                                                  ClipRRect(
                                                    borderRadius: const BorderRadius.vertical(
                                                      top: Radius.circular(14),
                                                    ),
                                                    child: exists
                                                        ? Image.file(File(path!),
                                                            cacheWidth: thumbPixels,
                                                            fit: BoxFit.cover,
                                                            semanticLabel: name,
                                                            errorBuilder: (_, __, ___) =>
                                                                Icon(Icons.broken_image_outlined,
                                                                    color: context.gama.textMuted))
                                                        : Center(child: Icon(
                                                            Icons.image_not_supported_outlined,
                                                            color: context.gama.textMuted,
                                                          )),
                                                  ),
                                                  Positioned(
                                                    top: 4, right: 4,
                                                    child: Material(
                                                      color: context.gama.surface.withValues(alpha: 0.92),
                                                      shape: const CircleBorder(),
                                                      child: IconButton(
                                                        tooltip: 'Baixar $name',
                                                        onPressed: exists
                                                            ? () => LibraryScreen.downloadEntry(context, it)
                                                            : null,
                                                        icon: const Icon(Icons.download_outlined),
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              )),
                                              Padding(
                                                padding: const EdgeInsets.all(10),
                                                child: Text(name,
                                                  maxLines: 1,
                                                  overflow: TextOverflow.ellipsis,
                                                  style: TextStyle(
                                                    color: context.gama.textSecondary,
                                                    fontSize: 12,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
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
