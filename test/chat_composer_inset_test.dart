import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gama/models/conversation.dart';
import 'package:gama/models/message.dart';
import 'package:gama/screens/chat_screen.dart';
import 'package:gama/services/conversation_service.dart';
import 'package:gama/services/settings_service.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Directory fixtureDirectory;
  late String conversationId;
  late String datedConversationId;
  late DateTime lastTimestamp;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await SettingsService.instance.init();
    fixtureDirectory = await Directory.systemTemp.createTemp(
      'gamma-chat-layout-',
    );
    Hive.init(fixtureDirectory.path);
    Hive.registerAdapter(ConversationAdapter());
    Hive.registerAdapter(MessageAdapter());

    final service = ConversationService.instance;
    await service.init();
    conversationId = service.currentConversationId!;
    for (var index = 0; index < 20; index++) {
      await service.addMessage(
        Message(
          id: 'm-$index',
          role: 'user',
          content: 'Mensagem $index',
          conversationId: conversationId,
        ),
        sync: false,
      );
    }
    final dated = await service.createDetachedConversation();
    datedConversationId = dated.id;
    final now = DateTime.now();
    final yesterday = DateTime(now.year, now.month, now.day - 1, 14, 23);
    lastTimestamp = DateTime(now.year, now.month, now.day, 15, 47);
    final entries = [
      ('user', 'Pedido antigo', yesterday),
      (
        'assistant',
        'Resposta antiga',
        yesterday.add(const Duration(minutes: 1)),
      ),
      ('user', 'Pedido novo', lastTimestamp),
      (
        'assistant',
        'Resposta nova',
        lastTimestamp.add(const Duration(minutes: 1)),
      ),
    ];
    for (final (index, entry) in entries.indexed) {
      final (role, content, timestamp) = entry;
      await service.addMessage(
        Message(
          id: 'dated-$index',
          role: role,
          content: content,
          timestamp: timestamp,
          conversationId: datedConversationId,
        ),
        sync: false,
      );
    }
  });

  tearDownAll(() async {
    await Hive.close();
    await fixtureDirectory.delete(recursive: true);
  });

  testWidgets(
    'O menu de comandos aumenta o espaço da lista e mantém o fim visível',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChatScreen(
              conversationId: conversationId,
              persistentSidebar: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final list = find
          .descendant(
            of: find.byKey(const ValueKey('chat-messages')),
            matching: find.byType(ListView),
          )
          .first;
      double bottomInset() => tester
          .widget<ListView>(list)
          .padding!
          .resolve(TextDirection.ltr)
          .bottom;
      final before = bottomInset();

      await tester.enterText(find.byType(TextField).first, '/modo');
      await tester.pumpAndSettle();

      expect(find.text('Mudar para Programar'), findsOneWidget);
      expect(bottomInset(), greaterThan(before));
      final lastMessage = find.text('Mensagem 19', findRichText: true);
      expect(lastMessage, findsOneWidget);
      expect(
        tester.getBottomLeft(lastMessage).dy,
        lessThan(tester.getTopLeft(find.text('/modo programar')).dy),
      );

      await tester.enterText(find.byType(TextField).first, '');
      await tester.pumpAndSettle();
      expect(bottomInset(), closeTo(before, 0.1));

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('Exibe datas e ações no último turno ou na mensagem tocada', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatScreen(
            conversationId: datedConversationId,
            persistentSidebar: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Ontem'), findsOneWidget);
    expect(find.text('Hoje'), findsOneWidget);
    expect(find.byTooltip('Ouvir resposta'), findsOneWidget);
    expect(find.byTooltip('Editar e reenviar'), findsNothing);

    await tester.tap(find.text('Resposta antiga', findRichText: true));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Ouvir resposta'), findsNWidgets(2));

    final user = find.text('Pedido novo', findRichText: true);
    await tester.tap(user);
    await tester.pumpAndSettle();
    expect(find.byTooltip('Ouvir resposta'), findsOneWidget);
    expect(find.byTooltip('Editar e reenviar'), findsOneWidget);
    final time = TimeOfDay.fromDateTime(lastTimestamp)
        .format(tester.element(user));
    expect(find.text(time), findsOneWidget);

    await tester.tap(find.byTooltip('Mais ações').first);
    await tester.pumpAndSettle();
    expect(find.text('Editar e reenviar'), findsOneWidget);
    expect(find.text('Tentar novamente'), findsOneWidget);
    expect(find.text('Baixar'), findsOneWidget);
    Navigator.of(tester.element(find.text('Baixar'))).pop();
    await tester.pumpAndSettle();

    await tester.longPress(user);
    await tester.pumpAndSettle();
    expect(find.text('Editar e reenviar'), findsOneWidget);
    expect(find.text('Tentar novamente'), findsOneWidget);
    expect(find.text('Baixar'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
