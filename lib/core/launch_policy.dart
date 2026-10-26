import 'package:flutter/foundation.dart';

/// Política para a distribuição da Gama.
///
/// Login de convidado é apenas ferramenta de desenvolvimento, pois a API de
/// produção exige um token Google válido e ignora X-User-Id do cliente.
/// Um futuro teste gratuito precisará de autenticação própria no backend.
class GamaLaunchPolicy {
  GamaLaunchPolicy._();

  /// Para testar localmente, use --dart-define=GAMA_ENABLE_GUEST_MODE=true
  /// juntamente com um backend de DESENVOLVIMENTO (GAMA_REQUIRE_AUTH=0).
  /// Nunca habilitado em builds release, mesmo com dart-define.
  static const bool guestLoginEnabled = !kReleaseMode && bool.fromEnvironment(
    'GAMA_ENABLE_GUEST_MODE',
    defaultValue: false,
  );
}
