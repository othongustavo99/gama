import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/gama_colors.dart';

class ImagesScreen extends StatefulWidget {
  const ImagesScreen({super.key});

  @override
  State<ImagesScreen> createState() => _ImagesScreenState();
}

class _ImagesScreenState extends State<ImagesScreen> {
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
    setState(() {
      _items = list
          .where((e) => e['kind'] == 'image')
          .toList()
          .reversed
          .toList();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: GamaColors.background,
      appBar: AppBar(
        backgroundColor: GamaColors.surface,
        title: const Text('Imagens'),
      ),
      body: _items.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Nenhuma imagem anexada ainda.\n'
                  'Use o clipe no chat e envie PNG/JPG.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: GamaColors.textMuted),
                ),
              ),
            )
          : GridView.builder(
              padding: const EdgeInsets.all(16),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                childAspectRatio: 1.1,
              ),
              itemCount: _items.length,
              itemBuilder: (_, i) {
                final it = _items[i];
                return Container(
                  decoration: BoxDecoration(
                    color: GamaColors.surfaceCard,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: GamaColors.border),
                  ),
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(
                        Icons.image_outlined,
                        color: GamaColors.accent,
                        size: 36,
                      ),
                      const SizedBox(height: 10),
                      Text(
                        it['name']?.toString() ?? '',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: GamaColors.textPrimary,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }
}
