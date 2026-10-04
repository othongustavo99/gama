import 'package:flutter/material.dart';

import '../core/gama_colors.dart';
import '../services/conversation_service.dart';
import '../widgets/app_drawer.dart';
import 'chat_screen.dart';
import 'images_screen.dart';
import 'library_screen.dart';
import 'plugins_screen.dart';
import 'projects_screen.dart';
import 'scheduled_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _service = ConversationService.instance;
  bool _booted = false;

  @override
  void initState() {
    super.initState();
    _openFreshConversation();
  }

  /// Toda vez que o app entra na home (após splash/login), abre conversa nova.
  Future<void> _openFreshConversation() async {
    if (_booted) return;
    _booted = true;
    await _service.createConversation(title: 'Nova conversa');
    if (mounted) setState(() {});
  }

  void _push(Widget page) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
  }

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
            onOpenImages: () {
              Navigator.pop(context);
              _push(const ImagesScreen());
            },
            onOpenLibrary: () {
              Navigator.pop(context);
              _push(const LibraryScreen());
            },
            onOpenProjects: () {
              Navigator.pop(context);
              _push(const ProjectsScreen());
            },
            onOpenScheduled: () {
              Navigator.pop(context);
              _push(const ScheduledScreen());
            },
            onOpenPlugins: () {
              Navigator.pop(context);
              _push(const PluginsScreen());
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
