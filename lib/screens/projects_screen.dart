import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../core/gama_colors.dart';

class ProjectsScreen extends StatefulWidget {
  const ProjectsScreen({super.key});

  @override
  State<ProjectsScreen> createState() => _ProjectsScreenState();
}

class _ProjectsScreenState extends State<ProjectsScreen> {
  List<Map<String, dynamic>> _projects = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('gama_projects') ?? '[]';
    setState(() {
      _projects = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
    });
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('gama_projects', jsonEncode(_projects));
  }

  Future<void> _add() async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: GamaColors.surfaceCard,
        title: const Text(
          'Novo projeto',
          style: TextStyle(color: GamaColors.textPrimary),
        ),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: const TextStyle(color: GamaColors.textPrimary),
          decoration: const InputDecoration(hintText: 'Nome do projeto'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text(
              'Cancelar',
              style: TextStyle(color: GamaColors.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text(
              'Criar',
              style: TextStyle(color: GamaColors.accent),
            ),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    setState(() {
      _projects.add({
        'id': const Uuid().v4(),
        'name': name,
        'notes': '',
        'createdAt': DateTime.now().toIso8601String(),
      });
    });
    await _save();
  }

  Future<void> _delete(String id) async {
    setState(() => _projects.removeWhere((p) => p['id'] == id));
    await _save();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: GamaColors.background,
      appBar: AppBar(
        backgroundColor: GamaColors.surface,
        title: const Text('Projetos'),
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: GamaColors.accent,
        onPressed: _add,
        child: const Icon(Icons.add, color: Colors.white),
      ),
      body: _projects.isEmpty
          ? const Center(
              child: Text(
                'Nenhum projeto ainda.\nToque em + para criar.',
                textAlign: TextAlign.center,
                style: TextStyle(color: GamaColors.textMuted),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: _projects.length,
              itemBuilder: (_, i) {
                final p = _projects[i];
                return Container(
                  margin: const EdgeInsets.only(bottom: 10),
                  decoration: BoxDecoration(
                    color: GamaColors.surfaceCard,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: GamaColors.border),
                  ),
                  child: ListTile(
                    title: Text(
                      p['name']?.toString() ?? '',
                      style: const TextStyle(color: GamaColors.textPrimary),
                    ),
                    subtitle: Text(
                      'Criado em ${p['createdAt']?.toString().substring(0, 10) ?? ''}',
                      style: const TextStyle(
                        color: GamaColors.textMuted,
                        fontSize: 12,
                      ),
                    ),
                    trailing: IconButton(
                      icon: const Icon(
                        Icons.delete_outline,
                        color: GamaColors.textMuted,
                      ),
                      onPressed: () => _delete(p['id'] as String),
                    ),
                  ),
                );
              },
            ),
    );
  }
}
