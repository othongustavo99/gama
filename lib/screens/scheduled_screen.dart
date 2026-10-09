import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../core/gama_colors.dart';

class _Reminder {
  final String id;
  String text;
  DateTime when;
  bool done;

  _Reminder({
    required this.id,
    required this.text,
    required this.when,
    this.done = false,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'text': text,
        'when': when.toIso8601String(),
        'done': done,
      };

  factory _Reminder.fromJson(Map<String, dynamic> j) => _Reminder(
        id: j['id'] as String,
        text: j['text'] as String? ?? '',
        when: DateTime.tryParse(j['when'] as String? ?? '') ?? DateTime.now(),
        done: j['done'] as bool? ?? false,
      );
}

/// Lembretes locais (SharedPreferences). Não depende do backend.
class ScheduledScreen extends StatefulWidget {
  const ScheduledScreen({super.key});

  @override
  State<ScheduledScreen> createState() => _ScheduledScreenState();
}

class _ScheduledScreenState extends State<ScheduledScreen> {
  static const _prefsKey = 'gama_local_reminders';
  final _uuid = const Uuid();
  List<_Reminder> _items = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    List<_Reminder> list = [];
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw) as List<dynamic>;
        list = decoded
            .whereType<Map>()
            .map((e) => _Reminder.fromJson(Map<String, dynamic>.from(e)))
            .toList();
      } catch (_) {}
    }
    list.sort((a, b) => a.when.compareTo(b.when));
    if (!mounted) return;
    setState(() {
      _items = list;
      _loading = false;
    });
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = jsonEncode(_items.map((e) => e.toJson()).toList());
    await prefs.setString(_prefsKey, encoded);
  }

  Future<void> _add() async {
    final textCtrl = TextEditingController();
    DateTime when = DateTime.now().add(const Duration(hours: 1));

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            return AlertDialog(
              backgroundColor: GamaColors.surfaceCard,
              title: const Text(
                'Novo lembrete',
                style: TextStyle(color: GamaColors.textPrimary),
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: textCtrl,
                    autofocus: true,
                    style: const TextStyle(color: GamaColors.textPrimary),
                    decoration: const InputDecoration(
                      hintText: 'Ex: revisar PR do Gamma',
                      hintStyle: TextStyle(color: GamaColors.textHint),
                    ),
                    maxLines: 2,
                  ),
                  const SizedBox(height: 16),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.event, color: GamaColors.accent),
                    title: Text(
                      _fmt(when),
                      style: const TextStyle(color: GamaColors.textPrimary),
                    ),
                    trailing: const Icon(
                      Icons.edit_calendar_rounded,
                      color: GamaColors.textMuted,
                    ),
                    onTap: () async {
                      final d = await showDatePicker(
                        context: ctx,
                        initialDate: when,
                        firstDate: DateTime.now().subtract(
                          const Duration(days: 1),
                        ),
                        lastDate: DateTime.now().add(const Duration(days: 365)),
                      );
                      if (d == null) return;
                      if (!ctx.mounted) return;
                      final t = await showTimePicker(
                        context: ctx,
                        initialTime: TimeOfDay.fromDateTime(when),
                      );
                      if (t == null) return;
                      setLocal(() {
                        when = DateTime(
                          d.year,
                          d.month,
                          d.day,
                          t.hour,
                          t.minute,
                        );
                      });
                    },
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Cancelar'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Salvar'),
                ),
              ],
            );
          },
        );
      },
    );

    if (ok != true) return;
    final text = textCtrl.text.trim();
    if (text.isEmpty) return;

    setState(() {
      _items.add(
        _Reminder(id: _uuid.v4(), text: text, when: when),
      );
      _items.sort((a, b) => a.when.compareTo(b.when));
    });
    await _persist();
  }

  Future<void> _toggleDone(_Reminder r) async {
    setState(() => r.done = !r.done);
    await _persist();
  }

  Future<void> _remove(_Reminder r) async {
    setState(() => _items.removeWhere((e) => e.id == r.id));
    await _persist();
  }

  static String _fmt(DateTime d) {
    final dd = d.day.toString().padLeft(2, '0');
    final mm = d.month.toString().padLeft(2, '0');
    final hh = d.hour.toString().padLeft(2, '0');
    final mi = d.minute.toString().padLeft(2, '0');
    return '$dd/$mm/${d.year}  $hh:$mi';
  }

  @override
  Widget build(BuildContext context) {
    final pending = _items.where((e) => !e.done).toList();
    final done = _items.where((e) => e.done).toList();

    return Scaffold(
      backgroundColor: GamaColors.background,
      appBar: AppBar(
        backgroundColor: GamaColors.surface,
        title: const Text('Agendado'),
        actions: [
          IconButton(
            tooltip: 'Novo lembrete',
            onPressed: _add,
            icon: const Icon(Icons.add_rounded),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: GamaColors.accent,
        onPressed: _add,
        child: const Icon(Icons.add, color: Colors.white),
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: GamaColors.accent),
            )
          : _items.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(28),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          width: 64,
                          height: 64,
                          decoration: BoxDecoration(
                            color: GamaColors.accentSoft,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: const Icon(
                            Icons.schedule_rounded,
                            color: GamaColors.accent,
                            size: 32,
                          ),
                        ),
                        const SizedBox(height: 20),
                        const Text(
                          'Nenhum lembrete ainda',
                          style: TextStyle(
                            color: GamaColors.textPrimary,
                            fontSize: 17,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 10),
                        const Text(
                          'Crie lembretes locais neste aparelho.\n'
                          'Eles ficam só no seu dispositivo (não vão para o servidor).',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: GamaColors.textMuted,
                            height: 1.4,
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 88),
                  children: [
                    if (pending.isNotEmpty) ...[
                      const Text(
                        'PENDENTES',
                        style: TextStyle(
                          color: GamaColors.textMuted,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.6,
                        ),
                      ),
                      const SizedBox(height: 8),
                      ...pending.map(_tile),
                    ],
                    if (done.isNotEmpty) ...[
                      const SizedBox(height: 20),
                      const Text(
                        'CONCLUÍDOS',
                        style: TextStyle(
                          color: GamaColors.textMuted,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.6,
                        ),
                      ),
                      const SizedBox(height: 8),
                      ...done.map(_tile),
                    ],
                  ],
                ),
    );
  }

  Widget _tile(_Reminder r) {
    final overdue = !r.done && r.when.isBefore(DateTime.now());
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: GamaColors.surfaceCard,
        borderRadius: BorderRadius.circular(14),
        child: ListTile(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          leading: IconButton(
            onPressed: () => _toggleDone(r),
            icon: Icon(
              r.done
                  ? Icons.check_circle_rounded
                  : Icons.radio_button_unchecked_rounded,
              color: r.done ? GamaColors.success : GamaColors.textMuted,
            ),
          ),
          title: Text(
            r.text,
            style: TextStyle(
              color: r.done ? GamaColors.textMuted : GamaColors.textPrimary,
              decoration: r.done ? TextDecoration.lineThrough : null,
            ),
          ),
          subtitle: Text(
            _fmt(r.when) + (overdue ? '  · atrasado' : ''),
            style: TextStyle(
              color: overdue ? GamaColors.error : GamaColors.textMuted,
              fontSize: 12,
            ),
          ),
          trailing: IconButton(
            onPressed: () => _remove(r),
            icon: const Icon(
              Icons.delete_outline_rounded,
              color: GamaColors.textMuted,
              size: 20,
            ),
          ),
        ),
      ),
    );
  }
}
