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
          message: 'Não foi possível preparar a autenticação da Gamma.',
        ),
      );
    }
  }
}
