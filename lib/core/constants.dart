class AppConstants {
  /// URL pública do backend do Gama.
  ///
  /// Depois de subir o servidor, troque somente este endereço pelo domínio
  /// HTTPS da sua API. Nunca coloque aqui o endereço do Ollama.
  static const String apiBaseUrl =
      'https://gama-production-592b.up.railway.app';

  /// Modelo padrão do Gama.
  static const String defaultModel = 'qwen2.5-coder:7b';

  /// Modelos que o aplicativo pode selecionar.
  static const List<String> availableModels = [
    'qwen2.5-coder:7b',
  ];
}
