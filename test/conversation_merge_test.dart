import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:gama/models/conversation.dart';
import 'package:gama/models/message.dart';
import 'package:gama/services/conversation_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temporary;
  final service = ConversationService.instance;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    temporary = await Directory.systemTemp.createTemp('gama-sync-merge-');
    Hive.init(temporary.path);
    if (!Hive.isAdapterRegistered(0)) Hive.registerAdapter(MessageAdapter());
    if (!Hive.isAdapterRegistered(1)) {
      Hive.registerAdapter(ConversationAdapter());
    }
    await service.init();
  });

  tearDownAll(() async {
    await Hive.close();
    if (await temporary.exists()) await temporary.delete(recursive: true);
  });

  test('resposta remota parcial não apaga o histórico local', () async {
    const id = 'fase1-historico';
    final localDate = DateTime.utc(2026, 10, 20);
    final remoteDate = DateTime.utc(2026, 10, 21);
    await Hive.box<Conversation>('conversations').put(
      id,
      Conversation(
        id: id,
        title: 'Original',
        mode: 'oficina_programar',
        createdAt: localDate,
        updatedAt: localDate,
      ),
    );
    for (var i = 0; i < 510; i++) {
      await Hive.box<Message>('messages').add(
        Message(
          id: 'historico-$i',
          role: 'user',
          content: 'Texto $i',
          conversationId: id,
          timestamp: localDate.add(Duration(seconds: i)),
        ),
      );
    }
    await service.applyRemoteConversation(
      id: id,
      title: 'Remoto',
      isPinned: true,
      mode: 'oficina_imagem',
      modeProvided: true,
      createdAt: localDate,
      updatedAt: remoteDate,
      messages: [
        Message(
          id: 'historico-509',
          role: 'user',
          content: 'Texto 509',
          conversationId: id,
        ),
        Message(
          id: 'historico-510',
          role: 'assistant',
          content: 'Nova resposta',
          conversationId: id,
        ),
      ],
    );
    expect(service.getMessages(id).length, 511);
    expect(service.getMessages(id).first.id, 'historico-0');
    expect(service.conversationById(id)?.mode, 'oficina_imagem');
    expect(service.conversationById(id)?.isPinned, isTrue);
  });

  test(
    'metadados locais mais recentes prevalecem, mas mensagens chegam',
    () async {
      const id = 'fase1-conflito';
      final latest = DateTime.utc(2026, 10, 22);
      final old = DateTime.utc(2026, 10, 20);
      await Hive.box<Conversation>('conversations').put(
        id,
        Conversation(
          id: id,
          title: 'Título local',
          mode: 'oficina_programar',
          updatedAt: latest,
        ),
      );
      await service.applyRemoteConversation(
        id: id,
        title: 'Título remoto antigo',
        isPinned: false,
        mode: null,
        modeProvided: false,
        createdAt: old,
        updatedAt: old,
        messages: [
          Message(
            id: 'somente-remoto',
            role: 'assistant',
            content: 'Chegou',
            conversationId: id,
          ),
        ],
      );
      expect(service.conversationById(id)?.title, 'Título local');
      expect(service.conversationById(id)?.mode, 'oficina_programar');
      expect(service.getMessages(id).single.id, 'somente-remoto');
    },
  );
}
