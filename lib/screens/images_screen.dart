import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/gama_colors.dart';
import '../widgets/loading_skeleton.dart';
import 'library_screen.dart';

class ImagesScreen extends StatefulWidget {
  const ImagesScreen({super.key});

  @override
  State<ImagesScreen> createState() => _ImagesScreenState();
}

class _ImagesScreenState extends State<ImagesScreen> {
  List<Map<String, dynamic>> _items = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('gama_library') ?? '[]';
    final list = (jsonDecode(raw) as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    if (!mounted) return;
    setState(() {
      _items = list
          .where((e) => (e['kind']?.toString() ?? '') == 'image')
          .toList()
          .reversed
          .toList();
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.gama.background,
      appBar: AppBar(
        backgroundColor: context.gama.surface,
        title: const Text('Imagens'),
      ),
      body: _loading
          ? const GamaSkeletonGrid(itemCount: 6)
          : _items.isEmpty
          ? Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Nenhuma imagem gerada ou anexada ainda.\n'
                  'Use o clipe no chat ou peça à Gama para criar uma imagem.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: context.gama.textMuted),
                ),
              ),
            )
          : GridView.builder(
              padding: const EdgeInsets.all(16),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                childAspectRatio: 0.9,
              ),
              itemCount: _items.length,
              itemBuilder: (_, i) {
                final it = _items[i];
                final path = it['path']?.toString();
                final name = it['name']?.toString() ?? '';
                final hasFile =
                    path != null && path.isNotEmpty && File(path).existsSync();

                return Material(
                  color: context.gama.surfaceCard,
                  borderRadius: BorderRadius.circular(14),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: () => LibraryScreen.openEntry(context, it),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              ClipRRect(
                                borderRadius: const BorderRadius.vertical(
                                  top: Radius.circular(14),
                                ),
                                child: hasFile
                                    ? Image.file(
                                        File(path!),
                                        fit: BoxFit.cover,
                                        errorBuilder: (_, __, ___) => Center(
                                          child: Icon(
                                            Icons.broken_image_outlined,
                                            color: context.gama.textMuted,
                                          ),
                                      ),
                                    )
                                    : Center(
                                        child: Icon(
                                          Icons.image_not_supported_outlined,
                                          color: context.gama.textMuted,
                                        ),
                                      ),
                              ),
                              Positioned(
                                top: 6,
                                right: 6,
                                child: Material(
                                  color: context.gama.surface.withValues(
                                    alpha: 0.9,
                                  ),
                                  shape: const CircleBorder(),
                                  child: IconButton(
                                    tooltip: 'Baixar imagem',
                                    onPressed: hasFile
                                        ? () => LibraryScreen.downloadEntry(
                                            context,
                                            it,
                                          )
                                        : null,
                                    icon: const Icon(
                                      Icons.download_outlined,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.all(10),
                          child: Text(
                            name,
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
            ),
    );
  }
}
