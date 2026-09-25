import 'package:flutter/material.dart';

import '../services/conversation_service.dart';
import '../widgets/app_drawer.dart';
import 'chat_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _service = ConversationService.instance;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _service,
      builder: (context, _) {
        final currentId = _service.currentConversationId;

        return Scaffold(
          backgroundColor: const Color(0xFF0D0D0D),
          drawer: AppDrawer(
            onNewChat: () async {
              await _service.createConversation();
              if (mounted) Navigator.pop(context);
            },
            onSelectConversation: (id) async {
              await _service.selectConversation(id);
              if (mounted) Navigator.pop(context);
            },
          ),
          body: currentId == null
              ? const Center(child: CircularProgressIndicator())
              : ChatScreen(key: ValueKey(currentId), conversationId: currentId),
        );
      },
    );
  }
}
