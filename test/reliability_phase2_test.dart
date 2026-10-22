import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gama/services/ollama_service.dart';
import 'package:gama/services/conversation_sync_service.dart';
import 'package:gama/utils/generation_session.dart';
import 'package:gama/utils/speech_recovery_policy.dart';

void main() {
  group('Fase 2: integridade do streaming', () {
    final service = OllamaService();

    test('mensagem completa dividida em chunks preserva conteúdo', () async {
      final text =
          '${jsonEncode({
            'message': {'content': 'Olá '},
          })}\n'
          '${jsonEncode({
            'message': {'content': 'mundo'},
          })}\n'
          '${jsonEncode({'done': true})}\n';
      final bytes = utf8.encode(text);
      final stream = Stream.fromIterable([
        bytes.sublist(0, 3),
        bytes.sublist(3, 18),
        bytes.sublist(18),
      ]);
      final received = await service.decodeNdjson(stream).toList();
      expect(
        received.map((e) => e.token).whereType<String>().join(),
        'Olá mundo',
      );
      expect(received.last.done, isTrue);
    });

    test('queda após texto parcial gera erro recuperável', () async {
      final events = <ChatStreamEvent>[];
      await expectLater(
        service
            .decodeNdjson(
              Stream.value(
                utf8.encode(
                  '${jsonEncode({
                    'message': {'content': 'Parcial'},
                  })}\n',
                ),
              ),
            )
            .listen(events.add)
            .asFuture<void>(),
        throwsA(isA<ChatApiException>()),
      );
      expect(
        events.map((event) => event.token).whereType<String>().join(),
        'Parcial',
      );
    });

    test('done sem newline final é aceito', () async {
      final events = await service
          .decodeNdjson(Stream.value(utf8.encode(jsonEncode({'done': true}))))
          .toList();
      expect(events.last.done, isTrue);
    });

    test('stream vazio não vira sucesso', () async {
      await expectLater(
        service.decodeNdjson(const Stream<List<int>>.empty()).toList(),
        throwsA(isA<ChatApiException>()),
      );
    });

    test('erro de servidor mantém falha explicativa', () async {
      await expectLater(
        service
            .decodeNdjson(
              Stream.value(
                utf8.encode('${jsonEncode({'error': '429 rate limit'})}\n'),
              ),
            )
            .toList(),
        throwsA(isA<ChatApiException>()),
      );
    });
  });

  group('Fase 2: retomada de reconhecimento de voz', () {
    test('erros temporários usam backoff limitado', () {
      final policy = SpeechRecoveryPolicy(maxFailures: 5);
      expect(
        policy.recordFailure(permanent: false),
        const Duration(milliseconds: 650),
      );
      expect(
        policy.recordFailure(permanent: false),
        const Duration(milliseconds: 1300),
      );
      expect(
        policy.recordFailure(permanent: false),
        const Duration(milliseconds: 2600),
      );
      expect(
        policy.recordFailure(permanent: false),
        const Duration(milliseconds: 5200),
      );
      expect(policy.recordFailure(permanent: false), isNull);
    });

    test('permissão negada não agenda novas tentativas', () {
      final policy = SpeechRecoveryPolicy();
      expect(policy.recordFailure(permanent: true), isNull);
    });

    test('sucesso zera contagem sem perder estado do campo', () {
      final policy = SpeechRecoveryPolicy();
      policy.recordFailure(permanent: false);
      policy.reset();
      expect(policy.consecutiveFailures, 0);
      expect(
        policy.recordFailure(permanent: false),
        const Duration(milliseconds: 650),
      );
    });
  });

  group('Fase 2: cancelamento e recuperação', () {
    test('evento tardio de uma geração cancelada é descartado', () {
      final guard = GenerationSession();
      final first = guard.start();
      expect(guard.isCurrent(first), true);
      guard.invalidate();
      expect(guard.isCurrent(first), false);
      final second = guard.start();
      expect(guard.isCurrent(first), false);
      expect(guard.isCurrent(second), true);
    });

    test('falhas de rede não se confundem com histórico remoto vazio', () {
      expect(
        () => ConversationSyncService.parseRemoteConversations(503, {
          'conversations': [],
        }),
        throwsStateError,
      );
      expect(
        () => ConversationSyncService.parseRemoteConversations(200, {}),
        throwsFormatException,
      );
      expect(
        () => ConversationSyncService.parseRemoteConversations(200, {
          'conversations': [null],
        }),
        throwsFormatException,
      );
      expect(
        ConversationSyncService.parseRemoteConversations(200, {
          'conversations': [],
        }),
        isEmpty,
      );
    });
  });
}
