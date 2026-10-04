class AppConstants {
  static const String apiBaseUrl =
      'https://gama-production-592b.up.railway.app';

  static const String modelProgramar = 'openai/gpt-oss-120b';
  static const String modelConversar = 'openai/gpt-oss-20b';

  /// Default = programar
  static const String defaultModel = modelProgramar;

  static const List<String> availableModels = [modelProgramar, modelConversar];
}
