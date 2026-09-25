import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'models/conversation.dart';
import 'models/message.dart';
import 'screens/home_screen.dart';
import 'services/conversation_service.dart';
import 'services/settings_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Hive.initFlutter();

  Hive.registerAdapter(MessageAdapter());
  Hive.registerAdapter(ConversationAdapter());

  try {
    await SettingsService.instance.init();
    await ConversationService.instance.init();
  } catch (e, stack) {
    // Se der erro de dados antigos, apaga as boxes e tenta de novo
    debugPrint('Erro na inicialização: $e');
    debugPrintStack(stackTrace: stack);

    await Hive.deleteBoxFromDisk('messages');
    await Hive.deleteBoxFromDisk('conversations');

    // Tenta novamente limpo
    await ConversationService.instance.init();
  }

  runApp(const GamaApp());
}

class GamaApp extends StatelessWidget {
  const GamaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Frequência40 — Gamma',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFF0D0D0D),
      ),
      home: const HomeScreen(),
    );
  }
}
