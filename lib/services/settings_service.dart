import 'package:shared_preferences/shared_preferences.dart';

import '../core/constants.dart';

enum GamaMode { programar, conversar }

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

  Future<void> setBaseUrl(String url) async {
    _ensureInitialized();
    final cleaned = url.trim().replaceAll(RegExp(r'/$'), '');
    if (cleaned.isEmpty) return;
    await _prefs.setString(_keyApiBaseUrl, cleaned);
  }

  Future<void> setModel(String model) async {
    _ensureInitialized();
    final m = model.trim();
    if (m.isEmpty) return;
    await _prefs.setString(_keyModel, m);
  }

  Future<void> setMode(GamaMode mode) async {
    _ensureInitialized();
    await _prefs.setString(
      _keyMode,
      mode == GamaMode.conversar ? 'conversar' : 'programar',
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
