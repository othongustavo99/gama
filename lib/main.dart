import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'core/gama_colors.dart';
import 'models/conversation.dart';
import 'models/message.dart';
import 'screens/home_screen.dart';
import 'services/conversation_service.dart';
import 'services/settings_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: GamaColors.background,
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );

  await Hive.initFlutter();

  Hive.registerAdapter(MessageAdapter());
  Hive.registerAdapter(ConversationAdapter());

  try {
    await SettingsService.instance.init();
    await ConversationService.instance.init();
  } catch (e, stack) {
    debugPrint('Erro na inicialização: $e');
    debugPrintStack(stackTrace: stack);

    await Hive.deleteBoxFromDisk('messages');
    await Hive.deleteBoxFromDisk('conversations');

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
        scaffoldBackgroundColor: GamaColors.background,
        colorScheme: const ColorScheme.dark(
          primary: GamaColors.accent,
          secondary: GamaColors.accent,
          surface: GamaColors.surface,
          error: GamaColors.error,
          onPrimary: Colors.white,
          onSecondary: Colors.white,
          onSurface: GamaColors.textPrimary,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: GamaColors.surface,
          foregroundColor: GamaColors.textPrimary,
          elevation: 0,
          centerTitle: false,
        ),
        dividerColor: GamaColors.divider,
        snackBarTheme: SnackBarThemeData(
          backgroundColor: GamaColors.surfaceCard,
          contentTextStyle: const TextStyle(color: GamaColors.textPrimary),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
        dialogTheme: DialogThemeData(
          backgroundColor: GamaColors.surfaceCard,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
        popupMenuTheme: PopupMenuThemeData(
          color: GamaColors.surfaceCard,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: GamaColors.surfaceInput,
          hintStyle: const TextStyle(color: GamaColors.textMuted),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: GamaColors.border),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: GamaColors.border),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: GamaColors.accent, width: 1.2),
          ),
        ),
      ),
      home: const HomeScreen(),
    );
  }
}

