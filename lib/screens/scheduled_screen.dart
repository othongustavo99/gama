import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../core/gama_colors.dart';

class ScheduledScreen extends StatefulWidget {
  const ScheduledScreen({super.key});

  @override
  State<ScheduledScreen> createState() => _ScheduledScreenState();
}

class _ScheduledScreenState extends State<ScheduledScreen> {
  List<Map<String, dynamic>> _items = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('gama_scheduled') ?? '[]';
    setState(() {
      _items = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
    });
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('gama_scheduled', jsonEncode(_items));
  }

  Future<void> _add() async {
    final ctrl = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: GamaColors.surfaceCard,
        title: const Text(
          'Lembrete / prompt agendado',
          style: TextStyle(color: GamaColors.textPrimary),
        ),
        content: TextField(
          controller: ctrl,
          maxLines: 3,
          style: const TextStyle(color: GamaColors.textPrimary),
          decoration: const InputDecoration(
            hintText: 'Ex: Revisar logs do backend toda segunda',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar', style: TextStyle(color: GamaColors.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('Salvar', style: TextStyle(color: GamaColors.accent)),
          ),
        ],
      ),
    );
    if (text == null || text.isEmpty) return;
    setState(() {
      _items.add({
        'id': const Uuid().v4(),
        'text': text,
        'createdAt': DateTime.now().toIso8601String(),
        'done': false,
      });
    });
    await _save();
  }

  Future<void> _toggle(String id) async {
    setState(() {
      for (final it in _items) {
        if (it['id'] == id) it['done'] = !(it['done'] == true);
      }
    });
    await _save();
  }

  Future<void> _delete(String id) async {
    setState(() => _items.removeWhere((e) => e['id'] == id));
    await _save();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: GamaColors.background,
      appBar: AppBar(
        backgroundColor: GamaColors.surface,
        title: const Text('Agendado'),
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: GamaColors.accent,
        onPressed: _add,
        child: const Icon(Icons.add, color: Colors.white),
      ),
      body: _items.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Nada agendado.\nCrie lembretes ou prompts para rodar depois.\n'
                  '(Execução automática em background virá numa próxima etapa.)',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: GamaColors.textMuted, height: 1.4),
                ),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: _items.length,
              itemBuilder: (_, i) {
                final it = _items[i];
                final done = it['done'] == true;
                return Container(
                  margin: const EdgeInsets.only(bottom: 10),
                  decoration: BoxDecoration(
                    color: GamaColors.surfaceCard,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: GamaColors.border),
                  ),
                  child: ListTile(
                    leading: IconButton(
                      icon: Icon(
                        done ? Icons.check_circle : Icons.circle_outlined,
                        color: done ? GamaColors.success : GamaColors.textMuted,
                      ),
                      onPressed: () => _toggle(it['id'] as String),
                    ),
                    title: Text(
                      it['text']?.toString() ?? '',
                      style: TextStyle(
                        color: GamaColors.textPrimary,
                        decoration: done ? TextDecoration.lineThrough : null,
                      ),
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline, color: GamaColors.textMuted),
                      onPressed: () => _delete(it['id'] as String),
                    ),
                  ),
                );
              },
            ),
    );
  }
}
