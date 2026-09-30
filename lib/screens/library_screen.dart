import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/gama_colors.dart';

/// Biblioteca local de anexos recentes (metadados).
class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  /// Chamado pelo chat ao anexar um arquivo.
  static Future<void> addEntry({
    required String name,
    required String kind,
    required int bytes,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('gama_library') ?? '[]';
    final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
    list.add({
      'name': name,
      'kind': kind,
      'bytes': bytes,
      'at': DateTime.now().toIso8601String(),
    });
    final trimmed = list.length > 100 ? list.sublist(list.length - 100) : list;
    await prefs.setString('gama_library', jsonEncode(trimmed));
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
    final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
    setState(() => _items = list.reversed.toList());
  }

  Future<void> _clear() async {
    final prefs = await SharedPreferences.getInstance();
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
                  'Anexos recentes do chat aparecem aqui.\n'
                  'Envie um arquivo no chat para começar.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: GamaColors.textMuted),
                ),
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: _items.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (_, i) {
                final it = _items[i];
                return Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: GamaColors.surfaceCard,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: GamaColors.border),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        _icon(it['kind']?.toString() ?? ''),
                        color: GamaColors.accent,
                        size: 22,
                      ),
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
                              '${it['kind']} · ${_fmtBytes(it['bytes'] as int? ?? 0)}',
                              style: const TextStyle(
                                color: GamaColors.textMuted,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
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
