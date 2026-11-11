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
}
