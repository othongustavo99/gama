/// Política local da apresentação da Gamma (uma vez por conta/dispositivo).
///
/// Usa o namespace hash da Fase 1C; nenhum e-mail ou identificador pessoal é
/// armazenado na chave da preferência.
abstract final class GamaWelcomePolicy {
  static String preferenceKey(String accountScopeKey) =>
      'gama_welcome_v1_$accountScopeKey';

  /// Não interrompe quem já tem histórico nem reapresenta o tutorial.
  static bool shouldOffer({
    required bool alreadySeen,
    required bool hasConversationHistory,
  }) => !alreadySeen && !hasConversationHistory;
}
