class AppConstants {
  /// URL pública do backend (Railway só com FastAPI — sem Ollama).
  static const String apiBaseUrl =
      'https://gama-production-592b.up.railway.app';

  /// Modelo padrão Groq — forte em programação e rápido.
  static const String defaultModel = 'openai/gpt-oss-120b';

  static const List<String> availableModels = [
    'openai/gpt-oss-120b',
    'openai/gpt-oss-20b',
  ];
}
