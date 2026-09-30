class AppConstants {
  /// API local (desenvolvimento)
  static const String apiBaseUrl = 'https://gama-production-592b.up.railway.app';

  /// Depois do deploy, troque nas Settings do app OU aqui:
  /// static const String apiBaseUrl = 'https://api.seudominio.com';

  /// Android Emulator:
  /// static const String apiBaseUrl = 'http://10.0.2.2:8000';

  /// Modelo padrão — no modo nuvem a API resolve o default
  /// (OpenRouter/Groq) se você mandar um nome local.
  static const String defaultModel = 'phi4-mini';
}
