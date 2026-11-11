import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gama/models/code_artifact.dart';
import 'package:gama/services/ollama_service.dart';
import 'package:gama/utils/fenced_code.dart';
import 'package:gama/widgets/windows_conversation_shortcuts.dart';

void main() {
  test('Cercas de código longas mantêm todos os caracteres', () {
    final source = List.generate(3000, (i) => 'linha $i 😀').join('\n');
    final markdown =
        'Introdução\n\n````dart lib/main.dart\n'
        '```markdown\n$source\n```\n````\n\n~~~python\nprint(1)\n~~~';
    final files = CodeArtifactFile.fromMarkdown(markdown);
    expect(files.map((file) => file.name), ['lib/main.dart', 'trecho-2.py']);
    expect(files.first.content, '```markdown\n$source\n```');
    expect(files.first.isLong, isTrue);
    expect(
      fencedCodeBlocks('~~~dart\nprint(1)\n~~~', streaming: true).single.end,
      isNull,
    );
    expect(
      fencedCodeBlocks('~~~dart\nprint(1)\n~~~\n', streaming: true).single.end,
      isNotNull,
    );
  });

  test('O stream entrega ao chat o ID exato para desfazer a memória', () async {
    final raw = [
      jsonEncode({
        'gama_meta': {
          'memory_saved': 'Apelido: Lua',
          'memory_undo_event_id': 'id-evento',
        },
      }),
      jsonEncode({'done': true}),
    ].join('\n');
    final events = await OllamaService()
        .decodeNdjson(Stream.value(utf8.encode(raw)))
        .toList();
    expect(events.first.memorySaved, 'Apelido: Lua');
    expect(events.first.memoryUndoEventId, 'id-evento');
    expect(events.last.done, isTrue);
  });

  testWidgets(
    'Ctrl+K foca a busca, Esc para a geração e Ctrl+N abre uma conversa',
    (tester) async {
      final search = ConversationSearchFocus();
      var created = 0;
      var stopped = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: WindowsConversationShortcuts(
            autofocus: true,
            onNewConversation: () {
              created++;
              search.closeDrawer();
            },
            onSearch: () => search.requestSearch(persistent: false),
            child: Scaffold(
              key: search.scaffoldKey,
              onDrawerChanged: search.drawerChanged,
              drawer: Drawer(child: TextField(focusNode: search.searchNode)),
              body: Builder(
                builder: (context) {
                  WindowsConversationShortcuts.stopControllerOf(context)!
                      .attach(search, () => stopped == 0, () => stopped++);
                  return const Text('Chat');
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(search.scaffoldKey.currentState!.isDrawerOpen, isTrue);
      expect(search.searchNode.hasFocus, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(stopped, 1);
      expect(search.scaffoldKey.currentState!.isDrawerOpen, isTrue);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(created, 1);
      expect(search.scaffoldKey.currentState!.isDrawerOpen, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
      search.dispose();
    },
    variant: const TargetPlatformVariant({TargetPlatform.windows}),
  );
}
