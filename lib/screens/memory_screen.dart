import 'package:flutter/material.dart';

import '../core/gama_colors.dart';
import '../widgets/loading_skeleton.dart';
import '../services/memory_service.dart';
import '../utils/error_logger.dart';

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
        content: TextField(
          controller: controller,
          autofocus: true,
          minLines: 2,
          maxLines: 5,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Salvar'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (text == null || text.length < 2) return;
    try {
      await _service.updateFact(fact.id, text);
      if (mounted) _reload();
      await _showUpdatedWithUndo(fact.id);
    } catch (error, stack) {
      logSwallowed(error, stack);
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Não foi possível atualizar a memória.'),
          ),
        );
    }
  }

  Future<void> _add() async {
    final controller = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Adicionar à memória'),
        content: TextField(
          controller: controller,
          autofocus: true,
          minLines: 2,
          maxLines: 5,
          decoration: const InputDecoration(
            hintText: 'Preferência ou informação útil',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Adicionar'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (text == null || text.length < 2) return;
    try {
      final saved = await _service.addFact(text);
      if (mounted) _reload();
      await _showUpdatedWithUndo(saved.id);
    } catch (error, stack) {
      logSwallowed(error, stack);
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Não foi possível salvar a memória.')),
        );
    }
  }


  Future<void> _showUpdatedWithUndo(String factId) async {
    if (!mounted) return;
    String? eventId;
    try {
      final history = await _service.history();
      for (final event in history) {
        if (event['fact_id'] == factId && event['undone'] != true &&
            event['action'] != 'UNDO') {
          eventId = event['event_id']?.toString();
          break;
        }
      }
    } catch (error, stack) {
      logSwallowed(error, stack);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: const Text('Memória atualizada'),
      action: eventId == null ? null : SnackBarAction(
        label: 'Desfazer',
        onPressed: () async {
          try {
            await _service.undo(eventId!);
            if (mounted) _reload();
          } catch (error, stack) {
            logSwallowed(error, stack);
          }
        },
      ),
    ));
  }

  Future<void> _togglePin(MemoryFact fact) async {
    try {
      await _service.pinFact(fact.id, !fact.pinned);
      if (mounted) _reload();
    } catch (error, stack) {
      logSwallowed(error, stack);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Não foi possível atualizar a fixação.')),
      );
    }
  }

  Future<void> _remove(MemoryFact fact) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Excluir memória?'),
        content: Text('Remover "${fact.text}"? Você poderá desfazer logo após.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Excluir')),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    try {
      final eventId = await _service.deleteFact(fact.id);
      if (!mounted) return;
      _reload();
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Memória excluída'),
          action: eventId == null ? null : SnackBarAction(
            label: 'Desfazer',
            onPressed: () async {
              try {
                await _service.undo(eventId);
                if (mounted) _reload();
              } catch (error, stack) {
                logSwallowed(error, stack);
              }
            },
          ),
        ),
      );
    } catch (error, stack) {
      logSwallowed(error, stack);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Não foi possível excluir a memória.')),
      );
    }
  }

  Future<void> _showHistory() async {
    try {
      final events = await _service.history();
      if (!mounted) return;
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (sheetContext) => SafeArea(
          child: SizedBox(
            height: MediaQuery.sizeOf(sheetContext).height * 0.65,
            child: Column(children: [
              const ListTile(title: Text('Histórico de alterações'),
                  subtitle: Text('Você pode desfazer alterações recentes.')),
              Expanded(child: ListView.builder(
                itemCount: events.length,
                itemBuilder: (context, i) {
                  final event = events[i];
                  final before = event['before'];
                  final after = event['after'];
                  String description = '';
                  if (after is Map) description = after['text']?.toString() ?? '';
                  if (description.isEmpty && before is Map) description = before['text']?.toString() ?? '';
                  final undone = event['undone'] == true || event['action'] == 'UNDO';
                  return ListTile(
                    title: Text(description.isEmpty ? 'Alteração de memória' : description,
                        maxLines: 2, overflow: TextOverflow.ellipsis),
                    subtitle: Text('${event['action']} • ${event['at']}'),
                    trailing: undone ? null : TextButton(
                      onPressed: () async {
                        try {
                          await _service.undo(event['event_id'].toString());
                          if (!sheetContext.mounted) return;
                          Navigator.of(sheetContext).pop();
                          _reload();
                        } catch (error, stack) {
                          logSwallowed(error, stack);
                          if (sheetContext.mounted) ScaffoldMessenger.of(sheetContext).showSnackBar(
                            const SnackBar(content: Text('Não foi possível desfazer esta alteração.')),
                          );
                        }
                      },
                      child: const Text('Desfazer'),
                    ),
                  );
                },
              )),
            ]),
          ),
        ),
      );
    } catch (error, stack) {
      logSwallowed(error, stack);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Não foi possível abrir o histórico.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Memória da Gama'), actions: [
      IconButton(tooltip: 'Histórico de memória', icon: const Icon(Icons.history), onPressed: _showHistory),
    ]),
    floatingActionButton: FloatingActionButton(
      onPressed: _add,
      child: const Icon(Icons.add),
    ),
    body: FutureBuilder<List<MemoryFact>>(
      future: _facts,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done)
          return const GamaSkeletonList(itemCount: 5);
        if (snapshot.hasError)
          return Center(
            child: TextButton(
              onPressed: _reload,
              child: const Text('Falha ao carregar. Tentar novamente'),
            ),
          );
        final facts = snapshot.data ?? [];
        if (facts.isEmpty)
          return const Center(child: Text('Ainda não há informações salvas.'));
        return ListView.separated(
          padding: const EdgeInsets.all(16),
          itemCount: facts.length,
          separatorBuilder: (_, __) => const SizedBox(height: 8),
          itemBuilder: (context, index) {
            final fact = facts[index];
            return Card(
              child: ListTile(
                title: Text(fact.text),
                subtitle: Text(
                  '${fact.pinned ? 'Fixada • ' : ''}${fact.kind == 'project' ? 'Projeto • ' : ''}${fact.source == 'user' ? 'Adicionada por você' : 'Salva pela Gama'}',
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: 'Editar',
                      onPressed: () => _edit(fact),
                      icon: const Icon(Icons.edit_outlined),
                    ),
                    IconButton(
                      tooltip: fact.pinned ? 'Desafixar memória' : 'Fixar memória',
                      onPressed: () => _togglePin(fact),
                      icon: Icon(fact.pinned ? Icons.push_pin : Icons.push_pin_outlined),
                    ),
                    IconButton(
                      tooltip: 'Excluir',
                      onPressed: () => _remove(fact),
                      icon: Icon(Icons.delete_outline, color: context.gama.error),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    ),
  );
}
