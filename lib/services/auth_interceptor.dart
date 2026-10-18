import 'dart:async';

import 'package:dio/dio.dart';

import '../core/constants.dart';
import 'auth_service.dart';
import 'identity_service.dart';

/// Aplica os cabeçalhos comuns em cada requisição HTTP do app.
/// O user id do cliente é apenas legado/diagnóstico; em produção, com
/// GAMA_REQUIRE_AUTH=1, o backend deriva a identidade do Bearer Google validado.
/// Sessões convidadas não autenticam em endpoints protegidos nesse modo.
class GammaAuthInterceptor extends Interceptor {
  GammaAuthInterceptor({required Dio client}) : _client = client;

  final Dio _client;
  static const _retryKey = 'gamaAuthRefreshRetried';

  bool _canRefresh(RequestOptions request) {
    final hasBearer =
        request.headers['Authorization']?.toString().startsWith('Bearer ') ??
        false;
    return hasBearer &&
        request.extra[_retryKey] != true &&
        request.data is! FormData &&
        request.data is! Stream;
  }

  Future<Response<dynamic>?> _retryWithFreshToken(
    RequestOptions request,
  ) async {
    final token = await AuthService.instance.refreshBearerToken();
    if (token == null || token.isEmpty) return null;
    request.headers['Authorization'] = 'Bearer $token';
    request.extra[_retryKey] = true;
    try {
      return await _client.fetch<dynamic>(request);
    } on DioException {
      return null;
    } catch (_) {
      return null;
    }
  }

  @override
  void onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) async {
    final request = response.requestOptions;
    if (response.statusCode == 401 && _canRefresh(request)) {
      final retry = await _retryWithFreshToken(request);
      if (retry != null) {
        handler.resolve(retry);
        return;
      }
    }
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) async {
    final status = err.response?.statusCode;
    final request = err.requestOptions;
    if (status == 401 && _canRefresh(request)) {
      final response = await _retryWithFreshToken(request);
      if (response != null) {
        handler.resolve(response);
        return;
      }
    }

    if (status == 401) {
      handler.reject(
        err.copyWith(
          message: 'A sessão Google expirou. Entre novamente e tente de novo.',
        ),
      );
      return;
    }
    if (status == 403) {
      handler.reject(
        err.copyWith(
          message: 'A conta autenticada não tem permissão para esta operação.',
        ),
      );
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
