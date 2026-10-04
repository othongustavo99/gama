import 'package:shared_preferences/shared_preferences.dart';

import '../core/constants.dart';

/// Modo de uso → modelo Groq.
enum GamaMode {
  programar, // openai/gpt-oss-120b
  conversar, // openai/gpt-oss-20b
}

class SettingsService {
  SettingsService._();
  static final SettingsService instance = SettingsService._();

  static const String _keyApiBaseUrl = 'frequencia40_api_base_url';
  static const String _keyModel = 'frequencia40_model';
  static const String _keyMode = 'gama_mode';
  static const String _keyTtsAuto = 'gama_tts_auto';
  static const String _keyFishVoiceId = 'gama_fish_voice_id';

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

  String get model {
    _ensureInitialized();
    // sempre deriva do modo (fonte da verdade)
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

  Future<void> setBaseUrl(String url) async {
    _ensureInitialized();
    final cleaned = url.trim().replaceAll(RegExp(r'/$'), '');
    await _prefs.setString(_keyApiBaseUrl, cleaned);
  }

  Future<void> setModel(String model) async {
    _ensureInitialized();
    await _prefs.setString(_keyModel, model.trim());
    // sincroniza modo
    if (model.contains('20b')) {
      await _prefs.setString(_keyMode, 'conversar');
    } else {
      await _prefs.setString(_keyMode, 'programar');
    }
  }

  Future<void> setMode(GamaMode mode) async {
    _ensureInitialized();
    await _prefs.setString(
      _keyMode,
      mode == GamaMode.conversar ? 'conversar' : 'programar',
    );
    await _prefs.setString(
      _keyModel,
      mode == GamaMode.conversar
          ? AppConstants.modelConversar
          : AppConstants.modelProgramar,
    );
  }

  Future<void> setTtsAuto(bool value) async {
    _ensureInitialized();
    await _prefs.setBool(_keyTtsAuto, value);
  }

  Future<void> setFishVoiceId(String id) async {
    _ensureInitialized();
    await _prefs.setString(_keyFishVoiceId, id.trim());
  }
}
