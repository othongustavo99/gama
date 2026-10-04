import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'core/gama_colors.dart';
import 'models/conversation.dart';
import 'models/message.dart';
import 'screens/splash_screen.dart';
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

  Object? startupError;

  try {
    await SettingsService.instance.init();
    await ConversationService.instance.init();
  } catch (e, stack) {
    // Nunca apague automaticamente as caixas do Hive em produção.
    // Um erro transitório de abertura não deve destruir todo o histórico.
    debugPrint('Erro na inicialização: $e');
    debugPrintStack(stackTrace: stack);
    startupError = e;

    try {
      await Hive.close();
      await Hive.initFlutter();
      await SettingsService.instance.init();
      await ConversationService.instance.init();
      startupError = null;
    } catch (retryError, retryStack) {
      debugPrint('Falha na segunda tentativa: $retryError');
      debugPrintStack(stackTrace: retryStack);
      startupError = retryError;
    }
  }

  runApp(
    startupError == null
        ? const GamaApp()
        : GamaStartupError(error: startupError!),
  );
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
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
        dialogTheme: DialogThemeData(
          backgroundColor: GamaColors.surfaceCard,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
        popupMenuTheme: PopupMenuThemeData(
          color: GamaColors.surfaceCard,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
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
      home: const SplashScreen(),
    );
  }
}

class GamaStartupError extends StatelessWidget {
  final Object error;

  const GamaStartupError({super.key, required this.error});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: Scaffold(
        backgroundColor: GamaColors.background,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.warning_amber_rounded,
                  color: GamaColors.accent,
                  size: 48,
                ),
                const SizedBox(height: 16),
                const Text(
                  'Não foi possível iniciar a Gamma',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: GamaColors.textPrimary,
                    fontSize: 19,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 10),
                const Text(
                  'O histórico não foi apagado. Feche e abra o app novamente.\n'
                  'Se o problema persistir, faça uma cópia dos dados antes de qualquer reparo.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: GamaColors.textSecondary,
                    height: 1.45,
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  error.toString(),
                  textAlign: TextAlign.center,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: GamaColors.textMuted,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
