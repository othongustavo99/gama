class AppConstants {
  /// URL pública do backend (Railway só com FastAPI — sem Ollama).
  static const String apiBaseUrl =
      'https://gama-production-592b.up.railway.app';

  /// Modelo padrão Groq — forte em programação e rápido.
  static const String defaultModel = 'llama-3.3-70b-versatile';

  /// Modelos liberados no app (devem bater com GROQ_MODELS no backend).
  static const List<String> availableModels = [
    'llama-3.3-70b-versatile',
    'llama-3.1-8b-instant',
  ];
}
