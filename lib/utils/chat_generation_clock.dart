import 'dart:async';

import 'package:flutter/foundation.dart';

/// Relógio de geração desacoplado do setState da ChatScreen.
/// Atualiza apenas os widgets de status que escutam este ValueListenable.
class ChatGenerationClock extends ValueNotifier<Duration> {
  ChatGenerationClock() : super(Duration.zero);

  Timer? _timer;
  DateTime? _startedAt;

  bool get isRunning => _startedAt != null;

  void start() {
    _timer?.cancel();
    _startedAt = DateTime.now();
    value = Duration.zero;
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      final started = _startedAt;
      if (started != null) value = DateTime.now().difference(started);
    });
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    final started = _startedAt;
    _startedAt = null;
    if (started != null) value = DateTime.now().difference(started);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _startedAt = null;
    super.dispose();
  }
}
