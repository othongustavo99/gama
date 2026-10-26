import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gama/services/ollama_service.dart';

void main() {
  final api = OllamaService();

  test('NDJSON inválido entre tokens não pode terminar como resposta completa', () async {
    final events = <ChatStreamEvent>[];
    final bytes = utf8.encode(
      '${jsonEncode({'message': {'content': 'Resposta parcial'}})}\n'
      '{invalido\n'
      '${jsonEncode({'done': true})}\n',
    );
    await expectLater(
      api.decodeNdjson(Stream.value(bytes)).listen(events.add).asFuture<void>(),
      throwsA(isA<ChatApiException>()),
    );
    expect(events.map((e) => e.token).whereType<String>().join(), 'Resposta parcial');
    expect(events.any((e) => e.done), isFalse);
  });

  test('payload NDJSON fragmentado mantém UTF-8 íntegro', () async {
    final raw = utf8.encode(
      '${jsonEncode({'message': {'content': 'Olá 🌎'}})}\n'
      '${jsonEncode({'done': true})}\n',
    );
    final chunks = <List<int>>[
      for (var start = 0; start < raw.length; start += 2)
        raw.sublist(start, start + 2 > raw.length ? raw.length : start + 2),
    ];
    final events = await api.decodeNdjson(Stream.fromIterable(chunks)).toList();
    expect(events.map((e) => e.token).whereType<String>().join(), 'Olá 🌎');
    expect(events.last.done, isTrue);
  });
}
