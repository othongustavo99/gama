import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/constants.dart';

enum GamaMode { programar, conversar }

class SettingsService extends ChangeNotifier {
  SettingsService._();
  static final SettingsService instance = SettingsService._();

  static const String _keyApiBaseUrl = 'frequencia40_api_base_url';
  static const String _keyModel = 'frequencia40_model';
  static const String _keyMode = 'gama_mode';
  static const String _keyTtsAuto = 'gama_tts_auto';
  static const String _keyFishVoiceId = 'gama_fish_voice_id';
  static const String _keyThemeMode = 'gama_theme_mode';
  static const String _keyFontScale = 'gama_font_scale';
  static const String _keyDeveloperMode = 'gama_developer_mode';

  late SharedPreferences _prefs;
  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    _prefs = await SharedPreferences.getInstance();
    _initialized = true;
  }

  void _ensureInitialized() {
    if (!_initialized) {
      throw StateError(
        'SettingsService não inicializado. Chame init() no main().',
      );
    }
  }

  String get baseUrl {
    _ensureInitialized();
    return _prefs.getString(_keyApiBaseUrl) ?? AppConstants.apiBaseUrl;
  }

  /// Modelo efetivo. Prefere o valor salvo se estiver na lista do backend;
  /// senão deriva do modo.
  String get model {
    _ensureInitialized();
    final saved = _prefs.getString(_keyModel)?.trim();
    if (saved != null && saved.isNotEmpty) return saved;
    return mode == GamaMode.conversar
        ? AppConstants.modelConversar
        : AppConstants.modelProgramar;
  }

  GamaMode get mode {
    _ensureInitialized();
    final v = _prefs.getString(_keyMode);
    if (v == 'conversar') return GamaMode.conversar;
    return GamaMode.programar;
  }

  bool get ttsAuto {
    _ensureInitialized();
    return _prefs.getBool(_keyTtsAuto) ?? false;
  }

  String get fishVoiceId {
    _ensureInitialized();
    return _prefs.getString(_keyFishVoiceId) ?? '';
  }

  ThemeMode get themeMode {
    _ensureInitialized();
    return switch (_prefs.getString(_keyThemeMode)) {
      'light' => ThemeMode.light,
      'system' => ThemeMode.system,
      _ => ThemeMode.dark,
    };
  }

  double get fontScale {
    _ensureInitialized();
    final value = _prefs.getDouble(_keyFontScale) ?? 1.0;
    return value.clamp(0.85, 1.30).toDouble();
  }

  bool get developerMode {
    _ensureInitialized();
    return _prefs.getBool(_keyDeveloperMode) ?? false;
  }

  Future<void> setBaseUrl(String url) async {
    _ensureInitialized();
    final cleaned = url.trim().replaceAll(RegExp(r'/$'), '');
    if (cleaned.isEmpty) return;
    await _prefs.setString(_keyApiBaseUrl, cleaned);
    notifyListeners();
  }

  Future<void> setModel(String model) async {
    _ensureInitialized();
    final m = model.trim();
    if (m.isEmpty) return;
    await _prefs.setString(_keyModel, m);
    notifyListeners();
  }

  Future<void> setMode(GamaMode mode) async {
    _ensureInitialized();
    await _prefs.setString(
      _keyMode,
      mode == GamaMode.conversar ? 'conversar' : 'programar',
    );
    notifyListeners();
  }

  Future<void> setTtsAuto(bool value) async {
    _ensureInitialized();
    await _prefs.setBool(_keyTtsAuto, value);
    notifyListeners();
  }

  Future<void> setFishVoiceId(String id) async {
    _ensureInitialized();
    await _prefs.setString(_keyFishVoiceId, id.trim());
    notifyListeners();
  }

  Future<void> setThemeMode(ThemeMode value) async {
    _ensureInitialized();
    final stored = switch (value) {
      ThemeMode.light => 'light',
      ThemeMode.system => 'system',
      _ => 'dark',
    };
    await _prefs.setString(_keyThemeMode, stored);
    notifyListeners();
  }

  Future<void> setFontScale(double value) async {
    _ensureInitialized();
    final safe = value.clamp(0.85, 1.30).toDouble();
    await _prefs.setDouble(_keyFontScale, safe);
    notifyListeners();
  }

  Future<void> setDeveloperMode(bool value) async {
    _ensureInitialized();
    await _prefs.setBool(_keyDeveloperMode, value);
    notifyListeners();
  }
}
