import 'package:flutter/material.dart';

import '../core/gama_colors.dart';
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
          backgroundColor: GamaColors.background,
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
              ? const Center(
                  child: SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: GamaColors.accent,
                    ),
                  ),
                )
              : ChatScreen(key: ValueKey(currentId), conversationId: currentId),
        );
      },
    );
  }
}
