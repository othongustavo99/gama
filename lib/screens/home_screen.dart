import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/gama_page_route.dart';
import '../core/gama_colors.dart';
import '../core/design_tokens.dart';
import '../core/welcome_policy.dart';
import '../services/local_account_scope.dart';
import '../widgets/welcome_experience.dart';
import '../widgets/loading_skeleton.dart';
import '../services/conversation_service.dart';
import '../services/conversation_sync_service.dart';
import '../models/oficina_kind.dart';
import '../widgets/app_drawer.dart';
import 'chat_screen.dart';
import 'images_screen.dart';
import 'library_screen.dart';
import 'plugins_screen.dart';
import 'projects_screen.dart';
import 'scheduled_screen.dart';
import 'oficina_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _service = ConversationService.instance;
  bool _booted = false;
  DateTime? _lastBackAt;

  @override
  void initState() {
    super.initState();
    _bootConversations();
  }

  /// Sempre inicia o app em uma NOVA conversa em branco.
  /// Rascunhos vazios da sessão anterior são apagados (não ficam salvos).
  /// Conversas que já receberam mensagem permanecem na lista.
  /// Depois sincroniza com o Railway (mesmo user_id = mesmo histórico).
  Future<void> _bootConversations() async {
    if (_booted) return;
    _booted = true;
    await _service.openFreshConversation();
    if (mounted) setState(() {});
    // Primeiro sincroniza: o tutorial nunca deve aparecer por engano para
    // alguém que já tem histórico salvo na outra plataforma.
    // A sincronização não bloqueia a apresentação da conversa atual.
    try {
      await ConversationSyncService.instance.syncAll();
    } catch (error) {
      debugPrint('Sincronização inicial não concluída: $error');
    }
    if (!mounted) return;
    setState(() {});
    await _offerWelcomeOnce();
  }

  Future<void> _offerWelcomeOnce() async {
    final scope = LocalAccountScope.current().key;
    if (scope == 'signed_out') return;
    final prefs = await SharedPreferences.getInstance();
    final key = GamaWelcomePolicy.preferenceKey(scope);
    final shouldOffer = GamaWelcomePolicy.shouldOffer(
      alreadySeen: prefs.getBool(key) ?? false,
      hasConversationHistory: _service.recentConversations.isNotEmpty ||
          _service.pinnedConversations.isNotEmpty,
    );
    if (!shouldOffer || !mounted) return;
    // Salvar ao oferecer evita popups repetidos ao voltar de outra tela.
    await prefs.setBool(key, true);
    if (!mounted || LocalAccountScope.current().key != scope) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _openWelcome();
    });
  }

  Future<void> _openWelcome() async {
    if (!mounted) return;
    final choice = await GamaWelcomeExperience.show(context);
    if (!mounted) return;
    if (choice == GamaWelcomeAction.oficina) {
      _push(const OficinaScreen());
    } else if (choice == GamaWelcomeAction.biblioteca) {
      _push(const LibraryScreen());
    }
    // Conversar ou dispensar: a pessoa já está na tela de conversa.
  }

  void _push(Widget page) {
    Navigator.of(context).push(GamaPageRoute(builder: (_) => page));
  }

  /// Voltar Android:
  /// 1) fecha drawer se aberto
  /// 2) fecha teclado se aberto
  /// 3) dois toques em ~2s → sai do app
  void _handleBack() {
    final scaffold = Scaffold.maybeOf(context);
    if (scaffold?.isDrawerOpen ?? false) {
      scaffold!.closeDrawer();
      return;
    }

    final focus = FocusScope.of(context);
    final keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;
    if (focus.hasFocus || keyboardOpen) {
      focus.unfocus();
      return;
    }

    final now = DateTime.now();
    if (_lastBackAt != null &&
        now.difference(_lastBackAt!) < const Duration(seconds: 2)) {
      SystemNavigator.pop();
      return;
    }
    _lastBackAt = now;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Toque voltar de novo para sair'),
        duration: Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _handleBack();
      },
      child: ListenableBuilder(
        listenable: _service,
        builder: (context, _) {
          final currentId = _service.currentConversationId;
          final currentConversation = currentId == null
              ? null
              : _service.conversationById(currentId);
          final oficinaKind = OficinaKindX.fromChatMode(
            currentConversation?.mode,
          );
          // Na janela estreita do Windows, prefira o drawer recolhível.
          final desktopSidebar =
              defaultTargetPlatform == TargetPlatform.windows &&
              MediaQuery.sizeOf(context).width >= 820;
          final appDrawer = AppDrawer(
            persistent: desktopSidebar,
            onNewChat: () async {
              // “Nova conversa” sempre começa no chat geral, inclusive quando
              // a ação veio do drawer da Oficina.
              await _service.openFreshConversation();
              if (mounted && !desktopSidebar) Navigator.pop(context);
            },
            onSelectConversation: (id) async {
              await _service.selectConversation(id);
              if (mounted && !desktopSidebar) Navigator.pop(context);
            },
            onOpenImages: () {
              if (!desktopSidebar) Navigator.pop(context);
              _push(const ImagesScreen());
            },
            onOpenLibrary: () {
              if (!desktopSidebar) Navigator.pop(context);
              _push(const LibraryScreen());
            },
            onOpenProjects: () {
              if (!desktopSidebar) Navigator.pop(context);
              _push(const ProjectsScreen());
            },
            onOpenScheduled: () {
              if (!desktopSidebar) Navigator.pop(context);
              _push(const ScheduledScreen());
            },
            onOpenPlugins: () {
              if (!desktopSidebar) Navigator.pop(context);
              _push(const PluginsScreen());
            },
            onOpenOficina: () {
              if (!desktopSidebar) Navigator.pop(context);
              _push(const OficinaScreen());
            },
            onOpenWelcome: () {
              if (!desktopSidebar) Navigator.pop(context);
              _openWelcome();
            },
          );

          return Scaffold(
            backgroundColor: context.gama.background,
            drawer: desktopSidebar ? null : appDrawer,
            body: AnimatedSwitcher(
              duration: MediaQuery.of(context).disableAnimations
                  ? Duration.zero
                  : GamaMotion.standard,
              switchInCurve: GamaMotion.curve,
              switchOutCurve: Curves.easeInCubic,
              child: currentId == null
                  ? const GamaSkeletonList(
                      key: ValueKey('home-loading'),
                      itemCount: 3,
                    )
                  : desktopSidebar
                  ? Row(
                      key: ValueKey('home-desktop-$currentId'),
                      children: [
                        SizedBox(width: 280, child: appDrawer),
                        VerticalDivider(
                          width: 1,
                          thickness: 1,
                          color: context.gama.divider,
                        ),
                        Expanded(
                          child: ChatScreen(
                            key: ValueKey(currentId),
                            conversationId: currentId,
                            oficinaKind: oficinaKind,
                            persistentSidebar: true,
                          ),
                        ),
                      ],
                    )
                  : ChatScreen(
                      key: ValueKey(currentId),
                      conversationId: currentId,
                      oficinaKind: oficinaKind,
                    ),
            ),
          );
        },
      ),
    );
  }
}
