class AppConstants {
  static const String apiBaseUrl =
      'https://gama-production-592b.up.railway.app';

  /// Modelo padrão
  static const String defaultModel = 'qwen2.5-coder:14b';

  /// Únicos modelos na tela de Settings
  static const List<String> availableModels = [
    'qwen2.5-coder:14b',
    'phi4-mini',
  ];
}
