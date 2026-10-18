import 'package:flutter/material.dart';

import '../core/gama_colors.dart';
import '../services/memory_service.dart';

class MemoryScreen extends StatefulWidget {
  const MemoryScreen({super.key});

  @override
  State<MemoryScreen> createState() => _MemoryScreenState();
}

class _MemoryScreenState extends State<MemoryScreen> {
  final _service = MemoryService();
  late Future<List<MemoryFact>> _facts;

  @override
  void initState() {
    super.initState();
    _facts = _service.listFacts();
  }

  void _reload() => setState(() => _facts = _service.listFacts());

  Future<void> _edit(MemoryFact fact) async {
    final controller = TextEditingController(text: fact.text);
    final text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Editar memória'),
        content: TextField(controller: controller, autofocus: true, minLines: 2, maxLines: 5),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text.trim()), child: const Text('Salvar')),
        ],
      ),
    );
    controller.dispose();
    if (text == null || text.length < 2) return;
    try {
      await _service.updateFact(fact.id, text);
      _reload();
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Não foi possível atualizar a memória.')));
    }
  }

  Future<void> _add() async {
    final controller = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Adicionar à memória'),
        content: TextField(controller: controller, autofocus: true, minLines: 2, maxLines: 5, decoration: const InputDecoration(hintText: 'Preferência ou informação útil')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text.trim()), child: const Text('Adicionar')),
        ],
      ),
    );
    controller.dispose();
    if (text == null || text.length < 2) return;
    try {
      await _service.addFact(text);
      _reload();
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Não foi possível salvar a memória.')));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Memória da Gama')),
        floatingActionButton: FloatingActionButton(onPressed: _add, child: const Icon(Icons.add)),
        body: FutureBuilder<List<MemoryFact>>(
          future: _facts,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
            if (snapshot.hasError) return Center(child: TextButton(onPressed: _reload, child: const Text('Falha ao carregar. Tentar novamente')));
            final facts = snapshot.data ?? [];
            if (facts.isEmpty) return const Center(child: Text('Ainda não há informações salvas.'));
            return ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: facts.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final fact = facts[index];
                return Card(
                  child: ListTile(
                    title: Text(fact.text),
                    subtitle: Text(fact.source == 'user' ? 'Adicionada por você' : 'Salva pela Gama'),
                    trailing: Wrap(mainAxisSize: MainAxisSize.min, children: [
                      IconButton(tooltip: 'Editar', onPressed: () => _edit(fact), icon: const Icon(Icons.edit_outlined)),
                      IconButton(tooltip: 'Excluir', onPressed: () async { await _service.deleteFact(fact.id); _reload(); }, icon: Icon(Icons.delete_outline, color: context.gama.error)),
                    ]),
                  ),
                );
              },
            );
          },
        ),
      );
}
