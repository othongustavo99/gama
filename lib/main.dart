import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'core/gama_colors.dart';
import 'models/conversation.dart';
import 'models/message.dart';
import 'screens/splash_screen.dart';
import 'services/conversation_service.dart';
import 'services/settings_service.dart';
import 'services/identity_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: Colors.black,
      systemNavigationBarIconBrightness: Brightness.light,
      systemNavigationBarDividerColor: Colors.black,
      systemNavigationBarContrastEnforced: false,
    ),
  );

  await Hive.initFlutter();

  Hive.registerAdapter(MessageAdapter());
  Hive.registerAdapter(ConversationAdapter());

  Object? startupError;

  try {
    await IdentityService.instance.init();
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

  ThemeData _theme(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final palette = isDark ? GamaPalette.dark() : GamaPalette.light();
    final background = palette.background;
    final surface = palette.surface;
    final textPrimary = palette.textPrimary;
    final textSecondary = palette.textSecondary;
    final border = palette.border;
    final scheme = isDark
        ? ColorScheme.dark(
            primary: palette.accent,
            secondary: palette.accentCool,
            surface: palette.surface,
            error: palette.error,
            onPrimary: Colors.white,
            onSecondary: Colors.white,
            onSurface: palette.textPrimary,
          )
        : ColorScheme.light(
            primary: palette.accentMuted,
            secondary: palette.accentCool,
            surface: surface,
            error: palette.error,
            onPrimary: Colors.white,
            onSecondary: Colors.white,
            onSurface: textPrimary,
          );
    return ThemeData(
      brightness: brightness,
      useMaterial3: true,
      extensions: [palette],
      scaffoldBackgroundColor: background,
      colorScheme: scheme,
      appBarTheme: AppBarTheme(
        backgroundColor: surface,
        foregroundColor: textPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: textPrimary,
          fontSize: 16,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.3,
        ),
      ),
      iconTheme: IconThemeData(color: textSecondary),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: surface,
        modalBackgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        dragHandleColor: textSecondary,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: palette.accent),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: palette.accent,
        selectionColor: palette.accentSoft,
        selectionHandleColor: palette.accent,
      ),
      dividerColor: border,
      snackBarTheme: SnackBarThemeData(
        backgroundColor: surface,
        contentTextStyle: TextStyle(color: textPrimary),
        behavior: SnackBarBehavior.floating,
        elevation: 8,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: border, width: 0.5),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surface,
        elevation: 12,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: border, width: 0.5),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: surface,
        elevation: 10,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: border, width: 0.5),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: palette.surfaceInput,
        hintStyle: TextStyle(color: textSecondary),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: palette.accent, width: 1.4),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: textPrimary,
          side: BorderSide(color: border),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: palette.accentMuted),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: surface,
        selectedColor: palette.accentSoft,
        side: BorderSide(color: border),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        labelStyle: TextStyle(color: textSecondary),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: SettingsService.instance,
      builder: (context, _) {
        final scale = SettingsService.instance.fontScale;
        final mode = SettingsService.instance.themeMode;
        final lightTheme = _theme(Brightness.light);
        final darkTheme = _theme(Brightness.dark);
        return MaterialApp(
          title: 'Gama',
          debugShowCheckedModeBanner: false,
          theme: lightTheme,
          darkTheme: darkTheme,
          themeMode: mode,
          locale: const Locale('pt', 'BR'),
          supportedLocales: const [Locale('pt', 'BR'), Locale('en')],
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          builder: (context, child) {
            final media = MediaQuery.of(context);
            final useLight =
                mode == ThemeMode.light ||
                (mode == ThemeMode.system &&
                    media.platformBrightness == Brightness.light);
            SystemChrome.setSystemUIOverlayStyle(
              SystemUiOverlayStyle(
                statusBarColor: Colors.transparent,
                statusBarIconBrightness: useLight
                    ? Brightness.dark
                    : Brightness.light,
                systemNavigationBarColor: useLight
                    ? const Color(0xFFF6F7F9)
                    : Colors.black,
                systemNavigationBarIconBrightness: useLight
                    ? Brightness.dark
                    : Brightness.light,
                systemNavigationBarDividerColor: useLight
                    ? const Color(0xFFD9DEE5)
                    : Colors.black,
                systemNavigationBarContrastEnforced: false,
              ),
            );
            final systemScale = media.textScaler.scale(1.0);
            return MediaQuery(
              data: media.copyWith(
                textScaler: TextScaler.linear(systemScale * scale),
              ),
              child: child ?? const SizedBox.shrink(),
            );
          },
          home: const SplashScreen(),
        );
      },
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
        backgroundColor: context.gama.background,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    color: context.gama.accentSoft,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: context.gama.accent.withValues(alpha: 0.35),
                    ),
                  ),
                  child: Icon(
                    Icons.warning_amber_rounded,
                    color: context.gama.accent,
                    size: 36,
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  'Não foi possível iniciar a Gama',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: context.gama.textPrimary,
                    fontSize: 19,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.3,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  'O histórico não foi apagado. Feche e abra o app novamente.\n'
                  'Se o problema persistir, faça uma cópia dos dados antes de qualquer reparo.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: context.gama.textSecondary,
                    height: 1.45,
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  error.toString(),
                  textAlign: TextAlign.center,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: context.gama.textMuted, fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
