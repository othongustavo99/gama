import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'models/message.dart';
import 'screens/chat_screen.dart';
import 'services/settings_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Hive.initFlutter();

  Hive.registerAdapter(MessageAdapter());

  await Hive.openBox<Message>('messages');

  await SettingsService.instance.init();

  runApp(const GamaApp());
}

class GamaApp extends StatelessWidget {
  const GamaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Frequência40 — Gama',

      debugShowCheckedModeBanner: false,

      theme: ThemeData(brightness: Brightness.dark, useMaterial3: true),

      home: const ChatScreen(),
    );
  }
}
