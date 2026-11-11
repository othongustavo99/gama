import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gama/models/conversation.dart';
import 'package:gama/models/message.dart';
import 'package:gama/screens/chat_screen.dart';
import 'package:gama/screens/code_diff_screen.dart';
import 'package:gama/widgets/code_artifact_panel.dart';
import 'package:gama/services/conversation_service.dart';
import 'package:gama/services/settings_service.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Directory fixtureDirectory;
  late String conversationId;
  late String datedConversationId;
  late String codeConversationId;
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
    final code = await service.createDetachedConversation();
    codeConversationId = code.id;
    final pair = [
      (
        'user',
        'Revise este código.\n\n```dart lib/main.dart\nfinal valor = 1;\n```',
      ),
      ('assistant', '```dart lib/main.dart\nfinal valor = 2;\n```'),
    ];
    for (final (index, entry) in pair.indexed) {
      await service.addMessage(
        Message(
          id: 'code-$index',
          role: entry.$1,
          content: entry.$2,
          conversationId: codeConversationId,
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
  testWidgets('cabeçalho acompanha título da conversa sem redesenhar a tela',
      (tester) async {
    final conversation = ConversationService.instance.conversationById(conversationId)!;
    final previousTitle = conversation.title;
    addTearDown(() {
      conversation.title = previousTitle;
      ConversationService.instance.notifyListeners();
    });
    conversation.title = 'Análise do projeto Flutter';
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: ChatScreen(
        conversationId: conversationId,
        persistentSidebar: true,
      )),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Análise do projeto Flutter'), findsOneWidget);
    conversation.title = 'Atualização da interface';
    ConversationService.instance.notifyListeners();
    await tester.pump();
    expect(find.text('Atualização da interface'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

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
    // Somente copiar e abrir o menu ficam visíveis por padrão.
    expect(find.byTooltip('Ouvir resposta'), findsNothing);
    expect(find.byTooltip('Editar e reenviar'), findsNothing);

    await tester.tap(find.text('Resposta antiga', findRichText: true));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Ouvir resposta'), findsOneWidget);

    final user = find.text('Pedido novo', findRichText: true);
    await tester.tap(user);
    await tester.pumpAndSettle();
    expect(find.byTooltip('Ouvir resposta'), findsNothing);
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

    // O long press passa a ser da seleção nativa, não abre a folha de ações.
    await tester.longPress(user);
    await tester.pumpAndSettle();
    expect(find.text('Baixar'), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'Artefatos abrem com abas e comparação e ações só editam o rascunho',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChatScreen(
              conversationId: codeConversationId,
              persistentSidebar: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Trabalhar no código'), findsOneWidget);
      expect(find.text('Explicar'), findsNothing);
      await tester.ensureVisible(find.text('Abrir artefatos'));
      await tester.tap(find.text('Abrir artefatos'));
      await tester.pumpAndSettle();

      final panel = find.byType(CodeArtifactPanel);
      expect(panel, findsOneWidget);
      expect(
        find.descendant(of: panel, matching: find.byType(ChoiceChip)),
        findsOneWidget,
      );
      if (defaultTargetPlatform == TargetPlatform.windows) {
        expect(find.byType(ChatScreen), findsOneWidget);
        expect(tester.getTopLeft(panel).dx, greaterThan(0));
      } else {
        expect(ModalRoute.of(tester.element(panel))?.isFirst, isFalse);
      }
      await tester.tap(find.byTooltip('Comparar alterações'));
      await tester.pumpAndSettle();
      expect(find.byType(CodeDiffView), findsOneWidget);
      expect(find.text('final valor = 2;'), findsWidgets);
      await tester.tap(find.byTooltip('Fechar artefatos'));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('Trabalhar no código'));
      await tester.tap(find.text('Trabalhar no código'));
      await tester.pumpAndSettle();
      expect(find.text('Explicar'), findsOneWidget);
      expect(find.text('Adicionar testes'), findsOneWidget);
      await tester.tap(find.text('Converter para…'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Python'));
      await tester.pumpAndSettle();
      final draft = tester
          .widget<TextField>(find.byType(TextField).first)
          .controller!
          .text;
      expect(draft, contains('para Python'));
      expect(
        ConversationService.instance.getMessages(codeConversationId),
        hasLength(2),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.windows,
      TargetPlatform.android,
    }),
  );
}
