/// Constantes centrais do app Gama.
class AppConstants {
  /// URL base da API (HTTPS obrigatório para APK release).
  static const String apiBaseUrl =
      'https://gama-production-592b.up.railway.app';

  /// Chave de API do app (enviada em X-API-Key). Defina no build/run:
  ///   flutter run --dart-define=GAMA_API_KEY=<mesma chave do servidor>
  /// Não escreva a chave direto no código nem commite.
  static const String apiKey = String.fromEnvironment(
    'GAMA_API_KEY',
    defaultValue: '',
  );

  /// Cabeçalhos de autenticação comuns a todas as chamadas ao backend.
  static Map<String, String> get authHeaders =>
      apiKey.isEmpty ? const <String, String>{} : {'X-API-Key': apiKey};

  /// Modo Programar — código, debug, arquitetura, análise de ZIP/PDF.
  static const String modelProgramar = 'openai/gpt-5.4-mini';

  /// Modo Conversar — diálogo rápido, voz, memória leve.
  static const String modelConversar = 'openai/gpt-5.4-mini';

  static const String defaultModel = modelProgramar;

  // Modelos padrão usados apenas como fallback quando o servidor está offline.
  // A lista real vem do endpoint /models; não repetimos dois modos como se
  // fossem modelos diferentes.
  static const List<String> availableModels = [modelProgramar];

  static const Map<String, String> modelLabels = {
    'openai/gpt-5.4-mini': 'GPT-5.4 Mini',
    'openai/gpt-4o': 'GPT-4o',
    'google/gemini-2.0-flash-001': 'Gemini 2.0 Flash',
    'deepseek/deepseek-chat': 'DeepSeek Chat',
    'qwen/qwen-2.5-coder-32b-instruct': 'Qwen 2.5 Coder',
  };

  static String labelFor(String modelId) {
    return modelLabels[modelId] ?? modelId.split('/').last;
  }
}
