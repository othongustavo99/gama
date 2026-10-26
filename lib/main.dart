import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:media_kit/media_kit.dart';

import 'core/gama_colors.dart';
import 'core/design_tokens.dart';
import 'models/conversation.dart';
import 'models/message.dart';
import 'screens/splash_screen.dart';
import 'services/conversation_service.dart';
import 'services/conversation_sync_service.dart';
import 'services/settings_service.dart';
import 'services/identity_service.dart';
import 'services/temporary_file_service.dart';

const _gamaLightSystemUiOverlayStyle = SystemUiOverlayStyle(
  statusBarColor: Color(0xFFFFFFFF),
  statusBarIconBrightness: Brightness.dark,
  statusBarBrightness: Brightness.light,
  systemNavigationBarColor: Color(0xFFF7F8FA),
  systemNavigationBarDividerColor: Color(0xFFF7F8FA),
  systemNavigationBarIconBrightness: Brightness.dark,
  systemNavigationBarContrastEnforced: false,
);

const _gamaDarkSystemUiOverlayStyle = SystemUiOverlayStyle(
  statusBarColor: Color(0xFF10141B),
  statusBarIconBrightness: Brightness.light,
  statusBarBrightness: Brightness.dark,
  systemNavigationBarColor: Color(0xFF0B0E13),
  systemNavigationBarDividerColor: Color(0xFF0B0E13),
  systemNavigationBarIconBrightness: Brightness.light,
  systemNavigationBarContrastEnforced: false,
);
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(_gamaDarkSystemUiOverlayStyle);

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
      await IdentityService.instance.init();
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

class GamaApp extends StatefulWidget {
  const GamaApp({super.key});

  @override
  State<GamaApp> createState() => _GamaAppState();
}

class _GamaAppState extends State<GamaApp> with WidgetsBindingObserver {
  Timer? _pendingGenerationSyncTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // A limpeza roda após o primeiro frame e jamais retarda a splash.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(TemporaryFileService.instance.cleanupAbandonedFiles());
    });
    unawaited(ConversationSyncService.instance.syncPendingGenerations());
    _pendingGenerationSyncTimer = Timer.periodic(const Duration(seconds: 15), (
      _,
    ) {
      if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
        unawaited(ConversationSyncService.instance.syncPendingGenerations());
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(ConversationSyncService.instance.syncPendingGenerations());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pendingGenerationSyncTimer?.cancel();
    super.dispose();
  }

  ThemeData _theme(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final palette = isDark ? GamaPalette.dark() : GamaPalette.light();
    final background = palette.background;
    final surface = palette.surface;
    final textPrimary = palette.textPrimary;
    final textSecondary = palette.textSecondary;
    final border = palette.border;
    final scheme = ColorScheme.fromSeed(
      seedColor: palette.accent,
      brightness: brightness,
      primary: palette.accent,
      secondary: palette.accentCool,
      surface: palette.surface,
      error: palette.error,
      onPrimary: Colors.white,
      onSecondary: Colors.white,
      onSurface: palette.textPrimary,
    );
    return ThemeData(
      brightness: brightness,
      useMaterial3: true,
      fontFamily: 'Inter',
      extensions: [palette],
      scaffoldBackgroundColor: background,
      colorScheme: scheme,
      appBarTheme: AppBarTheme(
        systemOverlayStyle: isDark
            ? _gamaDarkSystemUiOverlayStyle
            : _gamaLightSystemUiOverlayStyle,
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
          borderRadius: BorderRadius.circular(GamaRadius.md),
          side: BorderSide(color: border, width: 0.5),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surface,
        elevation: 12,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(GamaRadius.xl),
          side: BorderSide(color: border, width: 0.5),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: surface,
        elevation: 10,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(GamaRadius.md),
          side: BorderSide(color: border, width: 0.5),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: palette.surfaceInput,
        hintStyle: TextStyle(color: textSecondary),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(GamaRadius.md),
          borderSide: BorderSide(color: border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(GamaRadius.md),
          borderSide: BorderSide(color: border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(GamaRadius.md),
          borderSide: BorderSide(color: palette.accent, width: 1.4),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(GamaRadius.md),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: textPrimary,
          side: BorderSide(color: border),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(GamaRadius.md),
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
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(GamaRadius.md),
        ),
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
        final selectedAppearance = SettingsService.instance.appearance;
        final selectedMode = switch (selectedAppearance) {
          GamaAppearance.system => ThemeMode.system,
          GamaAppearance.light => ThemeMode.light,
          GamaAppearance.dark => ThemeMode.dark,
        };
        return MaterialApp(
          title: 'Gamma',
          debugShowCheckedModeBanner: false,
          theme: _theme(Brightness.light),
          darkTheme: _theme(Brightness.dark),
          themeMode: selectedMode,
          locale: const Locale('pt', 'BR'),
          supportedLocales: const [Locale('pt', 'BR'), Locale('en')],
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          builder: (context, child) {
            final media = MediaQuery.of(context);
            final systemScale = media.textScaler.scale(1.0);
            final isDark = Theme.of(context).brightness == Brightness.dark;
            return AnnotatedRegion<SystemUiOverlayStyle>(
              value: isDark
                  ? _gamaDarkSystemUiOverlayStyle
                  : _gamaLightSystemUiOverlayStyle,
              child: MediaQuery(
                data: media.copyWith(
                  textScaler: TextScaler.linear(systemScale * scale),
                  disableAnimations:
                      media.disableAnimations || SettingsService.instance.reduceMotion,
                ),
                child: child ?? const SizedBox.shrink(),
              ),
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
