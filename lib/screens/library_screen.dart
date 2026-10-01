import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/gama_colors.dart';

/// Biblioteca local de anexos (metadados + arquivo persistido).
class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  /// Copia o arquivo para pasta permanente e registra na biblioteca.
  static Future<void> addEntry({
    required String name,
    required String kind,
    required int bytes,
    String? sourcePath,
  }) async {
    String? savedPath;
    if (sourcePath != null && sourcePath.isNotEmpty) {
      try {
        final src = File(sourcePath);
        if (await src.exists()) {
          final dir = await getApplicationDocumentsDirectory();
          final libDir = Directory(p.join(dir.path, 'gama_library'));
          if (!await libDir.exists()) {
            await libDir.create(recursive: true);
          }
          final safe = name.replaceAll(RegExp(r'[^\w\.\-]+'), '_');
          final dest = p.join(
            libDir.path,
            '${DateTime.now().millisecondsSinceEpoch}_$safe',
          );
          await src.copy(dest);
          savedPath = dest;
        }
      } catch (_) {
        savedPath = sourcePath; // fallback: tenta o path original
      }
    }

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('gama_library') ?? '[]';
    final list = (jsonDecode(raw) as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    list.add({
      'name': name,
      'kind': kind,
      'bytes': bytes,
      'path': savedPath,
      'at': DateTime.now().toIso8601String(),
    });
    final trimmed = list.length > 100 ? list.sublist(list.length - 100) : list;
    await prefs.setString('gama_library', jsonEncode(trimmed));
  }

  /// Abre arquivo/imagem da biblioteca.
  static Future<void> openEntry(
    BuildContext context,
    Map<String, dynamic> it,
  ) async {
    final path = it['path']?.toString();
    final name = it['name']?.toString() ?? 'arquivo';
    final kind = it['kind']?.toString() ?? '';

    if (path == null || path.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Arquivo antigo sem caminho salvo. Anexe de novo para poder abrir.',
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

    if (kind == 'image') {
      if (!context.mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => Dialog(
          backgroundColor: GamaColors.surface,
          insetPadding: const EdgeInsets.all(16),
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
                        style: const TextStyle(
                          color: GamaColors.textPrimary,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(
                        Icons.close,
                        color: GamaColors.textMuted,
                      ),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: InteractiveViewer(
                  child: Image.file(
                    file,
                    fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) => const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'Não foi possível carregar a imagem',
                        style: TextStyle(color: GamaColors.textMuted),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: () async {
                  await OpenFilex.open(path);
                },
                icon: const Icon(Icons.open_in_new, color: GamaColors.accent),
                label: const Text(
                  'Abrir com app externo',
                  style: TextStyle(color: GamaColors.accent),
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      );
      return;
    }

    final result = await OpenFilex.open(path);
    if (result.type != ResultType.done && context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Não abriu: ${result.message}')));
    }
  }

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  List<Map<String, dynamic>> _items = [];

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
    setState(() => _items = list.reversed.toList());
  }

  Future<void> _clear() async {
    final prefs = await SharedPreferences.getInstance();
    // apaga arquivos persistidos
    try {
      final dir = await getApplicationDocumentsDirectory();
      final libDir = Directory(p.join(dir.path, 'gama_library'));
      if (await libDir.exists()) {
        await libDir.delete(recursive: true);
      }
    } catch (_) {}
    await prefs.setString('gama_library', '[]');
    setState(() => _items = []);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: GamaColors.background,
      appBar: AppBar(
        backgroundColor: GamaColors.surface,
        title: const Text('Biblioteca'),
        actions: [
          if (_items.isNotEmpty)
            TextButton(
              onPressed: _clear,
              child: const Text(
                'Limpar',
                style: TextStyle(color: GamaColors.error),
              ),
            ),
        ],
      ),
      body: _items.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Nenhum anexo ainda.\n'
                  'Use o clipe no chat (câmera, galeria ou arquivos).',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: GamaColors.textMuted),
                ),
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: _items.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final it = _items[index];
                final kind = it['kind']?.toString() ?? '';
                final path = it['path']?.toString();
                final hasFile = path != null && path.isNotEmpty;

                return Material(
                  color: GamaColors.surfaceCard,
                  borderRadius: BorderRadius.circular(12),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => LibraryScreen.openEntry(context, it),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                      child: Row(
                        children: [
                          Icon(_icon(kind), color: GamaColors.accent, size: 22),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  it['name']?.toString() ?? '',
                                  style: const TextStyle(
                                    color: GamaColors.textPrimary,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                Text(
                                  '${it['kind']} · ${_fmtBytes(it['bytes'] as int? ?? 0)}'
                                  '${hasFile ? '' : ' · (sem arquivo)'}',
                                  style: const TextStyle(
                                    color: GamaColors.textMuted,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Icon(
                            hasFile
                                ? Icons.chevron_right_rounded
                                : Icons.block_flipped,
                            color: GamaColors.textMuted,
                            size: 20,
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
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
