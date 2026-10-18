import 'package:dio/dio.dart';

import '../core/constants.dart';
import 'auth_service.dart';
import 'identity_service.dart';

/// Aplica os cabeçalhos comuns em cada requisição HTTP do app.
/// O user id do cliente é apenas legado/diagnóstico; em produção, com
/// GAMA_REQUIRE_AUTH=1, o backend deriva a identidade do Bearer Google validado.
/// Sessões convidadas não autenticam em endpoints protegidos nesse modo.
class GammaAuthInterceptor extends Interceptor {
  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    final status = err.response?.statusCode;
    if (status == 401 || status == 403) {
      final message = AppConstants.apiKey.isEmpty
          ? 'A API recusou o acesso (HTTP $status). Este build está sem GAMA_API_KEY. '
                'Se o Railway exige essa chave, gere o APK com --dart-define=GAMA_API_KEY=SUA_CHAVE '
                'e confirme a autenticação da sessão.'
          : 'A API recusou o acesso (HTTP $status). Confira se GAMA_API_KEY no build corresponde '
                'à chave do Railway e se a sessão de autenticação continua válida.';
      handler.reject(err.copyWith(message: message));
      return;
    }
    handler.next(err);
  }

  @override
  void onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    options.headers.addAll(AppConstants.authHeaders);
    options.headers['X-User-Id'] = IdentityService.instance.userId;
    try {
      final token = await AuthService.instance.bearerToken();
      if (token != null && token.isNotEmpty) {
        options.headers['Authorization'] = 'Bearer $token';
      }
      handler.next(options);
    } catch (error, stackTrace) {
      handler.reject(
        DioException(
          requestOptions: options,
          error: error,
          stackTrace: stackTrace,
          type: DioExceptionType.unknown,
          message: 'Não foi possível preparar a autenticação da Gama.',
        ),
      );
    }
  }
}
