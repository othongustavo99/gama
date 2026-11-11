import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gama/models/conversation.dart';
import 'package:gama/models/message.dart';
import 'package:gama/services/conversation_service.dart';
import 'package:gama/services/identity_service.dart';
import 'package:gama/services/local_account_scope.dart';
import 'package:gama/widgets/app_drawer.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temporary;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await IdentityService.instance.init();
    temporary = await Directory.systemTemp.createTemp('gama-phase6-drawer-');
    Hive.init(temporary.path);
    if (!Hive.isAdapterRegistered(0)) Hive.registerAdapter(MessageAdapter());
    if (!Hive.isAdapterRegistered(1)) Hive.registerAdapter(ConversationAdapter());
    await ConversationService.instance.init();

    final scope = LocalAccountScope.current();
    final conversations = Hive.box<Conversation>(scope.conversationsBox);
    final messages = Hive.box<Message>(scope.messagesBox);
    for (var i = 0; i < 80; i++) {
      final id = 'phase6-conversation-$i';
      await conversations.put(id, Conversation(
        id: id,
        title: i == 79 ? 'Conversa especial' : 'Conversa número $i',
        updatedAt: DateTime(2026, 11, 11, 12).subtract(Duration(minutes: i)),
      ));
      await messages.add(Message(
        id: 'phase6-message-$i',
        role: 'user',
        conversationId: id,
        content: i == 78 ? 'conteúdo exclusivo da pesquisa' : 'Mensagem de teste',
      ));
    }
  });

  tearDownAll(() async {
    await Hive.close();
    if (await temporary.exists()) await temporary.delete(recursive: true);
  });

  Future<void> openDrawer(WidgetTester tester) async {
    final scaffold = GlobalKey<ScaffoldState>();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        key: scaffold,
        drawer: AppDrawer(onNewChat: () {}, onSelectConversation: (_) {}),
        body: const SizedBox.expand(),
      ),
    ));
    scaffold.currentState!.openDrawer();
    await tester.pumpAndSettle();
  }

  testWidgets('lista de conversas usa construção sob demanda', (tester) async {
    await openDrawer(tester);
    final list = tester.widget<ListView>(find.byKey(const Key('drawer-history-list')));
    expect(list.childrenDelegate, isA<SliverChildBuilderDelegate>());
    // A lista de 80 conversas não precisa montar 80 ListTiles de uma vez.
    expect(find.byType(ListTile).evaluate().length, lessThan(35));
  });

  testWidgets('busca recebe debounce, encontra título e conteúdo', (tester) async {
    await openDrawer(tester);
    final search = find.byType(TextField).first;

    await tester.enterText(search, 'especial');
    await tester.pump(const Duration(milliseconds: 100));
    // Resultado só é aplicado depois da pausa de digitação.
    expect(find.text('Conversa número 0'), findsWidgets);
    await tester.pump(const Duration(milliseconds: 120));
    expect(find.text('Conversa especial'), findsOneWidget);
    expect(find.text('Conversa número 0'), findsNothing);

    await tester.enterText(search, 'exclusivo');
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Conversa número 78'), findsOneWidget);
    await tester.enterText(search, '');
    await tester.pump();
    expect(find.text('Conversa número 0'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
