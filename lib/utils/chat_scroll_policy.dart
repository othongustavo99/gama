/// Limiares de scroll isolados da UI para serem testados sem frames.
class ChatScrollPolicy {
  const ChatScrollPolicy._();

  static bool nearEnd(double pixels, double maxExtent,
      {double tolerance = 140}) => maxExtent - pixels <= tolerance;

  /// O usuário que saiu do acompanhamento automático nunca deve ser puxado
  /// para baixo apenas por chegar um token ou por uma imagem carregar.
  static bool shouldFollow({
    required bool forced,
    required bool userFollowing,
  }) => forced || userFollowing;

  /// Compensa a inserção de mensagens anteriores acima do viewport.
  /// Limita o deslocamento ao novo intervalo permitido pelo ScrollPosition.
  static double restoredOffset({
    required double oldOffset,
    required double oldMaxExtent,
    required double newMaxExtent,
    required double minExtent,
  }) => (oldOffset + (newMaxExtent - oldMaxExtent))
      .clamp(minExtent, newMaxExtent < minExtent ? minExtent : newMaxExtent)
      .toDouble();
}
