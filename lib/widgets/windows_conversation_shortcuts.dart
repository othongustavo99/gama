import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class ConversationSearchFocus {
  final scaffoldKey = GlobalKey<ScaffoldState>();
  final searchNode = FocusNode(debugLabel: 'Busca de conversas');
  bool _focusAfterOpen = false;

  void requestSearch({required bool persistent}) {
    final scaffold = scaffoldKey.currentState;
    if (persistent || scaffold?.isDrawerOpen == true) {
      searchNode.requestFocus();
    } else if (scaffold != null) {
      _focusAfterOpen = true;
      scaffold.openDrawer();
    }
  }

  void drawerChanged(bool open) {
    if (open && _focusAfterOpen) searchNode.requestFocus();
    _focusAfterOpen = false;
  }

  void closeDrawer() => scaffoldKey.currentState?.closeDrawer();

  void dispose() => searchNode.dispose();
}

class ConversationStopController {
  Object? _owner;
  bool Function()? _canStop;
  VoidCallback? _stop;

  void attach(Object owner, bool Function() canStop, VoidCallback stop) {
    _owner = owner;
    _canStop = canStop;
    _stop = stop;
  }

  void detach(Object owner) {
    if (!identical(_owner, owner)) return;
    _owner = null;
    _canStop = null;
    _stop = null;
  }

  bool get canStop => _canStop?.call() ?? false;

  void stop() => _stop?.call();
}

class WindowsConversationShortcuts extends StatefulWidget {
  const WindowsConversationShortcuts({
    super.key,
    required this.onNewConversation,
    required this.onSearch,
    required this.child,
    this.autofocus = false,
  });

  final VoidCallback onNewConversation;
  final VoidCallback onSearch;
  final Widget child;
  final bool autofocus;

  static ConversationStopController? stopControllerOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<_ConversationStopScope>()
          ?.controller;

  @override
  State<WindowsConversationShortcuts> createState() =>
      _WindowsConversationShortcutsState();
}

class _WindowsConversationShortcutsState
    extends State<WindowsConversationShortcuts> {
  final _stop = ConversationStopController();

  @override
  Widget build(BuildContext context) {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows)
      return widget.child;
    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.escape): _StopConversationIntent(),
        SingleActivator(LogicalKeyboardKey.keyN, control: true):
            _NewConversationIntent(),
        SingleActivator(LogicalKeyboardKey.keyK, control: true):
            _SearchConversationIntent(),
      },
      child: Actions(
        actions: {
          _StopConversationIntent: _StopConversationAction(_stop),
          _NewConversationIntent: CallbackAction<_NewConversationIntent>(
            onInvoke: (_) {
              widget.onNewConversation();
              return null;
            },
          ),
          _SearchConversationIntent: CallbackAction<_SearchConversationIntent>(
            onInvoke: (_) {
              widget.onSearch();
              return null;
            },
          ),
        },
        child: _ConversationStopScope(
          controller: _stop,
          child: Focus(autofocus: widget.autofocus, child: widget.child),
        ),
      ),
    );
  }
}

class _ConversationStopScope extends InheritedWidget {
  const _ConversationStopScope({
    required this.controller,
    required super.child,
  });

  final ConversationStopController controller;

  @override
  bool updateShouldNotify(_ConversationStopScope oldWidget) =>
      controller != oldWidget.controller;
}

class _StopConversationIntent extends Intent {
  const _StopConversationIntent();
}

class _StopConversationAction extends Action<_StopConversationIntent> {
  _StopConversationAction(this.controller);

  final ConversationStopController controller;

  @override
  bool isEnabled(_StopConversationIntent intent) => controller.canStop;

  @override
  void invoke(_StopConversationIntent intent) => controller.stop();
}

class _NewConversationIntent extends Intent {
  const _NewConversationIntent();
}

class _SearchConversationIntent extends Intent {
  const _SearchConversationIntent();
}
