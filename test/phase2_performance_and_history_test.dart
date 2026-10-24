import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gama/services/ollama_service.dart';
import 'package:gama/utils/chat_history_window.dart';
import 'package:gama/utils/chat_scroll_policy.dart';
import 'package:gama/utils/chat_generation_clock.dart';

void main() {
  group('Fase 2: histórico paginado sem descartar mensagens', () {
    test('histórico longo começa nas 60 últimas mensagens', () {
      final window = ChatHistoryWindow();
      expect(window.start(500), 440);
      expect(window.count(500), 60);
      expect(window.listLength(500), 61); // cabeçalho
      expect(window.messageIndex(1, 500), 440);
      expect(window.messageIndex(60, 500), 499);
      expect(window.remaining(500), 440);
    });

    test('carregar anteriores preserva índices reais e inclui todo histórico', () {
      final window = ChatHistoryWindow(initialSize: 2, pageSize: 3);
      expect(window.start(7), 5);
      expect(window.loadEarlier(7), 3);
      expect(window.start(7), 2);
      expect(window.messageIndex(1, 7), 2);
      expect(window.messageIndex(5, 7), 6);
      expect(window.loadEarlier(7), 2);
      expect(window.hasOlder(7), isFalse);
      expect(window.listLength(7), 7);
      expect(window.messageIndex(0, 7), 0);
      expect(window.loadEarlier(7), 0);
      window.reset();
      expect(window.start(7), 5);
    });

    test('mensagens novas não impedem acesso às antigas', () {
      final window = ChatHistoryWindow(initialSize: 2, pageSize: 2);
      expect(window.start(5), 3);
      expect(window.start(6), 4);
      window.loadEarlier(6);
      expect(window.start(6), 2);
      expect(window.messageIndex(1, 6), 2);
    });
  });

  group('Fase 2: scroll previsível', () {
    test('restaura a posição depois de inserir mensagens acima', () {
      expect(
        ChatScrollPolicy.restoredOffset(
          oldOffset: 350,
          oldMaxExtent: 2000,
          newMaxExtent: 2700,
          minExtent: 0,
        ),
        1050,
      );
      expect(
        ChatScrollPolicy.restoredOffset(
          oldOffset: 50,
          oldMaxExtent: 100,
          newMaxExtent: 0,
          minExtent: 0,
        ),
        0,
      );
    });

    test('não puxa a leitura quando o acompanhamento foi interrompido', () {
      expect(ChatScrollPolicy.shouldFollow(
        forced: false, userFollowing: false,
      ), isFalse);
      expect(ChatScrollPolicy.shouldFollow(
        forced: false, userFollowing: true,
      ), isTrue);
      expect(ChatScrollPolicy.shouldFollow(
        forced: true, userFollowing: false,
      ), isTrue);
      expect(ChatScrollPolicy.nearEnd(1890, 2000), isTrue);
      expect(ChatScrollPolicy.nearEnd(1800, 2000), isFalse);
    });
  });

  group('Fase 2: streaming incremental robusto', () {
    test('UTF-8 e múltiplos eventos divididos em pedaços arbitrários', () async {
      final payload = '${jsonEncode({'message': {'content': 'Café ☕ e programação'}})}\n'
          '${jsonEncode({'message': {'content': ' 🚀'}})}\r\n'
          '${jsonEncode({'done': true})}';
      final data = utf8.encode(payload);
      final stream = Stream<List<int>>.fromIterable(
        List.generate(data.length, (i) => [data[i]]),
      );
      final events = await OllamaService().decodeNdjson(stream).toList();
      expect(events.map((e) => e.token).whereType<String>().join(),
          'Café ☕ e programação 🚀');
      expect(events.last.done, isTrue);
    });

    test('perda de conexão preserva tokens e gera erro, nunca sucesso', () async {
      final events = <ChatStreamEvent>[];
      final incomplete = jsonEncode({'message': {'content': 'parcial'}});
      final subscription = OllamaService()
          .decodeNdjson(Stream.value(utf8.encode(incomplete)))
          .listen(events.add);
      await expectLater(subscription.asFuture<void>(),
          throwsA(isA<ChatApiException>()));
      expect(events.single.token, 'parcial');
    });
  });

  test('relógio pode iniciar, parar e liberar recursos', () {
    final clock = ChatGenerationClock();
    expect(clock.isRunning, false);
    clock.start();
    expect(clock.isRunning, true);
    clock.stop();
    expect(clock.isRunning, false);
    clock.dispose();
  });
}
