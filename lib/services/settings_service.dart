import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/constants.dart';

enum GamaMode { programar, conversar }

/// Preferência persistida. Não afeta modelos, memória nem histórico.
enum GamaAppearance { system, light, dark }

class SettingsService extends ChangeNotifier {
  SettingsService._();
  static final SettingsService instance = SettingsService._();

  static const String _keyApiBaseUrl = 'frequencia40_api_base_url';
  static const String _keyModel = 'frequencia40_model';
  static const String _keyMode = 'gama_mode';
  static const String _keyTtsAuto = 'gama_tts_auto';
  static const String _keyFishVoiceId = 'gama_fish_voice_id';
  static const String _keyFontScale = 'gama_font_scale';
  static const String _keyDeveloperMode = 'gama_developer_mode';
  static const String _keyAppearance = 'gama_appearance';
  static const String _keyReduceMotion = 'gama_reduce_motion';

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

  /// Modelo efetivo do modo principal. A Oficina seleciona seu próprio modelo.
  String get model {
    _ensureInitialized();
    return modelForMode(mode);
  }

  static String modelForMode(GamaMode mode) => mode == GamaMode.conversar
      ? AppConstants.modelConversar
      : AppConstants.modelProgramar;

  GamaMode get mode {
    _ensureInitialized();
    final v = _prefs.getString(_keyMode);
    if (v == 'programar' || v == 'trabalhar') return GamaMode.programar;
    return GamaMode.conversar;
  }

  bool get ttsAuto {
    _ensureInitialized();
    return _prefs.getBool(_keyTtsAuto) ?? false;
  }

  String get fishVoiceId {
    _ensureInitialized();
    return _prefs.getString(_keyFishVoiceId) ?? '';
  }

  double get fontScale {
    _ensureInitialized();
    final value = _prefs.getDouble(_keyFontScale) ?? 1.0;
    return value.clamp(0.85, 1.30).toDouble();
  }

  GamaAppearance get appearance {
    _ensureInitialized();
    return switch (_prefs.getString(_keyAppearance)) {
      'light' => GamaAppearance.light,
      'dark' => GamaAppearance.dark,
      _ => GamaAppearance.dark,
    };
  }

  bool get reduceMotion {
    _ensureInitialized();
    return _prefs.getBool(_keyReduceMotion) ?? false;
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
    final value = model.trim();
    if (value != AppConstants.modelConversar &&
        value != AppConstants.modelProgramar) return;
    await _prefs.setString(_keyModel, value);
    await _prefs.setString(
      _keyMode,
      value == AppConstants.modelConversar ? 'conversar' : 'programar',
    );
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

  Future<void> setFontScale(double value) async {
    _ensureInitialized();
    final safe = value.clamp(0.85, 1.30).toDouble();
    await _prefs.setDouble(_keyFontScale, safe);
    notifyListeners();
  }

  Future<void> setAppearance(GamaAppearance value) async {
    _ensureInitialized();
    await _prefs.setString(_keyAppearance, value.name);
    notifyListeners();
  }

  Future<void> setReduceMotion(bool value) async {
    _ensureInitialized();
    await _prefs.setBool(_keyReduceMotion, value);
    notifyListeners();
  }

  Future<void> setDeveloperMode(bool value) async {
    _ensureInitialized();
    await _prefs.setBool(_keyDeveloperMode, value);
    notifyListeners();
  }
}
