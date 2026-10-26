import 'package:dio/dio.dart';

import '../core/constants.dart';
import '../models/commercial_account.dart';
import 'auth_interceptor.dart';
import 'identity_service.dart';
import 'settings_service.dart';

/// Apenas leitura. Não oferece compras, nem altera cotas ou créditos.
class CommercialService {
  CommercialService._();
  static final CommercialService instance = CommercialService._();

  Future<CommercialAccount> fetchAccount() async {
    if (IdentityService.instance.provider != 'google') {
      throw const CommercialAccountException(
        'Entre com sua conta Google para consultar seu plano.',
      );
    }
    final accountId = IdentityService.instance.userId;
    final dio = Dio(BaseOptions(
      baseUrl: SettingsService.instance.baseUrl,
      connectTimeout: const Duration(seconds: 12),
      receiveTimeout: const Duration(seconds: 20),
      headers: AppConstants.authHeaders,
    ));
    dio.interceptors.add(GammaAuthInterceptor(client: dio));
    try {
      final response = await dio.get<dynamic>('/account/commercial');
      if (IdentityService.instance.userId != accountId ||
          IdentityService.instance.provider != 'google') {
        throw const CommercialAccountException(
          'A conta foi alterada. Abra esta tela novamente.',
        );
      }
      final json = response.data;
      if (json is! Map) throw const FormatException('Resposta inválida');
      return CommercialAccount.fromJson(Map<String, dynamic>.from(json));
    } on CommercialAccountException {
      rethrow;
    } on DioException catch (error) {
      final status = error.response?.statusCode;
      if (status == 401 || status == 403) {
        throw const CommercialAccountException(
          'Não foi possível autenticar sua conta. Entre novamente com o Google.',
        );
      }
      if (status == 404) {
        throw const CommercialAccountException(
          'Seu servidor ainda não oferece a consulta de planos. Atualize o backend.',
        );
      }
      throw const CommercialAccountException(
        'Não foi possível consultar seu plano. Verifique a conexão e tente novamente.',
      );
    } on FormatException {
      throw const CommercialAccountException(
        'O servidor enviou informações incompletas do plano. Atualize o backend.',
      );
    } finally {
      dio.close();
    }
  }
}

class CommercialAccountException implements Exception {
  final String message;
  const CommercialAccountException(this.message);
  @override
  String toString() => message;
}
