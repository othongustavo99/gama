import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gama/models/conversation.dart';
import 'package:gama/models/message.dart';
import 'package:gama/screens/projects_screen.dart';
import 'package:gama/screens/settings_screen.dart';
import 'package:gama/services/conversation_service.dart';
import 'package:gama/services/identity_service.dart';
import 'package:gama/services/local_account_scope.dart';
import 'package:gama/widgets/app_drawer.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temporary;
  final service = ConversationService.instance;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await IdentityService.instance.init();
    temporary = await Directory.systemTemp.createTemp('gama-frontend-phase3-');
    Hive.init(temporary.path);
    if (!Hive.isAdapterRegistered(0)) Hive.registerAdapter(MessageAdapter());
    if (!Hive.isAdapterRegistered(1)) Hive.registerAdapter(ConversationAdapter());
    await service.init();
    const id = 'frontend-phase3-pinned';
    await Hive.box<Conversation>(LocalAccountScope.current().conversationsBox).put(id, Conversation(
      id: id,
      title: 'Projeto fixado',
      isPinned: true,
    ));
    await Hive.box<Message>(LocalAccountScope.current().messagesBox).add(Message(
      id: 'frontend-phase3-message',
      role: 'user',
      content: 'Precisamos melhorar a navegação',
      conversationId: id,
    ));
  });

  tearDownAll(() async {
    await Hive.close();
    if (await temporary.exists()) await temporary.delete(recursive: true);
  });

  testWidgets('menu mantém uma ação de nova conversa e integra fixadas ao histórico',
      (tester) async {
    final scaffold = GlobalKey<ScaffoldState>();
    var pinnedOpens = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        key: scaffold,
        drawer: AppDrawer(
          onNewChat: () {},
          onSelectConversation: (_) {},
          onOpenProjects: () => pinnedOpens++,
          onOpenOficina: () {},
          onOpenLibrary: () {},
          onOpenScheduled: () {},
          onOpenPlugins: () {},
        ),
        body: const Center(child: Text('Conversa')),
      ),
    ));
    scaffold.currentState!.openDrawer();
    await tester.pumpAndSettle();
    expect(find.text('Nova conversa'), findsOneWidget);
    expect(find.text('Ferramentas'), findsOneWidget);
    expect(find.text('Histórico'), findsOneWidget);
    expect(find.text('Agendamentos'), findsOneWidget);
    expect(find.text('Recursos e integrações'), findsOneWidget);
    expect(find.text('Conversas fixadas'), findsNothing);
    expect(find.byKey(const Key('drawer-account-entry')), findsOneWidget);
    expect(find.text('Sair da conta'), findsNothing);
    await tester.tap(find.byKey(const Key('drawer-pinned-shortcut')));
    expect(pinnedOpens, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('perfil leva à conta e exige confirmação para sair', (tester) async {
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
    await tester.tap(find.byKey(const Key('drawer-account-entry')));
    await tester.pumpAndSettle();
    expect(find.text('Conta e privacidade'), findsOneWidget);
    final logout = find.byKey(const Key('account-sign-out'));
    await tester.ensureVisible(logout);
    await tester.tap(logout);
    await tester.pumpAndSettle();
    expect(find.text('Sair da conta?'), findsOneWidget);
    expect(find.textContaining('não exclui suas conversas'), findsOneWidget);
    await tester.tap(find.text('Cancelar'));
    await tester.pumpAndSettle();
    expect(find.text('Conta e privacidade'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ajustes apresentam grupos, recursos e sem seletor de modo',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SettingsScreen()));
    for (final label in ['Experiência', 'Recursos', 'Privacidade',
      'Aparência', 'Voz', 'Memória', 'Recursos e integrações', 'Plano', 'Conta']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.text('Altere o modo na tela principal.'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('fixadas possuem título e ação clara para desafixar', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: ProjectsScreen()));
    await tester.pumpAndSettle();
    expect(find.text('Conversas fixadas'), findsOneWidget);
    expect(find.text('Projeto fixado'), findsOneWidget);
    await tester.tap(find.byTooltip('Desafixar conversa'));
    await tester.pumpAndSettle();
    expect(find.text('Desafixar conversa?'), findsOneWidget);
    await tester.tap(find.text('Cancelar'));
    await tester.pumpAndSettle();
    expect(find.text('Projeto fixado'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
