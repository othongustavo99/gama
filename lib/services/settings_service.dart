import 'package:shared_preferences/shared_preferences.dart';

import '../core/constants.dart';

class SettingsService {
  SettingsService._();

  static final SettingsService instance = SettingsService._();

  static const String _keyApiBaseUrl = 'frequencia40_api_base_url';

  static const String _keyModel = 'frequencia40_model';

  late SharedPreferences _prefs;

  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) {
      return;
    }

    _prefs = await SharedPreferences.getInstance();

    _initialized = true;
  }

  void _ensureInitialized() {
    if (!_initialized) {
      throw StateError(
        'SettingsService não foi inicializado. '
        'Chame SettingsService.instance.init() '
        'no main().',
      );
    }
  }

  String get baseUrl {
    _ensureInitialized();

    return _prefs.getString(_keyApiBaseUrl) ?? AppConstants.apiBaseUrl;
  }

  String get model {
    _ensureInitialized();

    return _prefs.getString(_keyModel) ?? AppConstants.defaultModel;
  }

  Future<void> setBaseUrl(String url) async {
    _ensureInitialized();

    final cleaned = url.trim().replaceAll(RegExp(r'/$'), '');

    await _prefs.setString(_keyApiBaseUrl, cleaned);
  }

  Future<void> setModel(String model) async {
    _ensureInitialized();

    await _prefs.setString(_keyModel, model.trim());
  }
}
