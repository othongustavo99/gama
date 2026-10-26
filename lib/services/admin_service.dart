import 'package:dio/dio.dart';
import '../core/constants.dart';
import 'auth_interceptor.dart';
import 'identity_service.dart';
import 'settings_service.dart';

/// Administração Beta. Autorização real é verificada EM CADA REQUISIÇÃO
/// pelo backend com ID token Google; controles visuais não substituem ACL.
class AdminService {
  AdminService._();
  static final AdminService instance = AdminService._();

  Future<T> _request<T>(Future<T> Function(Dio dio) action) async {
    if (IdentityService.instance.provider != 'google') {
      throw const AdminException('Entre com sua conta Google.');
    }
    final id = IdentityService.instance.userId;
    final dio = Dio(BaseOptions(
      baseUrl: SettingsService.instance.baseUrl,
      connectTimeout: const Duration(seconds: 12),
      receiveTimeout: const Duration(seconds: 25),
      headers: AppConstants.authHeaders,
    ));
    dio.interceptors.add(GammaAuthInterceptor(client: dio));
    try {
      final result = await action(dio);
      if (id != IdentityService.instance.userId ||
          IdentityService.instance.provider != 'google') {
        throw const AdminException('A conta foi alterada. Abra a tela novamente.');
      }
      return result;
    } on DioException catch (error) {
      final code = error.response?.statusCode;
      if (code == 401 || code == 403) {
        throw const AdminException('Esta conta não possui acesso administrativo.');
      }
      if (code == 404) {
        throw const AdminException('Atualize o backend para a Fase 3F.');
      }
      // Rejeição comercial não deve ser confundida com conexão.
      if (code == 409 || code == 422) {
        final data = error.response?.data;
        final detail = data is Map ? data['detail'] : null;
        throw AdminException(detail is String ? detail : 'Revise os dados informados.');
      }
      throw const AdminException('Não foi possível conectar ao painel. Tente novamente.');
    } finally {
      dio.close();
    }
  }

  Future<bool> checkAccess() => _request((dio) async {
    try {
      final response = await dio.get<dynamic>('/admin/access');
      return response.data is Map && response.data['is_admin'] == true;
    } on DioException catch (error) {
      if (error.response?.statusCode == 403) return false;
      rethrow;
    }
  });

  Future<AdminOverview> overview(int days) => _request((dio) async {
    final response = await dio.get<dynamic>('/admin/overview', queryParameters: {'days': days});
    final data = response.data;
    if (data is! Map) throw const AdminException('Indicadores inválidos.');
    return AdminOverview.fromJson(Map<String, dynamic>.from(data));
  });

  Future<AdminAccount> findAccount(String email) => _request((dio) async {
    final response = await dio.post<dynamic>('/admin/commercial/account-by-email', data: {'email': email.trim()});
    final data = response.data;
    if (data is! Map) throw const AdminException('Resposta comercial inválida.');
    return AdminAccount.fromJson(Map<String, dynamic>.from(data));
  });

  Future<Map<String, dynamic>> assignPlan({
    required String email, required String plan,
    required String requestId, int? days,
  }) => _request((dio) async {
    final response = await dio.post<dynamic>('/admin/commercial/assign-plan-by-email', data: {
      'email': email.trim(), 'plan': plan, 'request_id': requestId,
      'duration_days': days,
    });
    if (response.data is! Map) throw const AdminException('Resposta comercial inválida.');
    return Map<String, dynamic>.from(response.data as Map);
  });

  Future<Map<String, dynamic>> adjustCredits({
    required String email, required int delta,
    required String reason, required String requestId,
  }) => _request((dio) async {
    final response = await dio.post<dynamic>('/admin/commercial/adjust-credits-by-email', data: {
      'email': email.trim(), 'delta': delta, 'reason': reason.trim(),
      'request_id': requestId,
    });
    if (response.data is! Map) throw const AdminException('Resposta comercial inválida.');
    return Map<String, dynamic>.from(response.data as Map);
  });
}

class AdminException implements Exception {
  final String message;
  const AdminException(this.message);
  @override
  String toString() => message;
}

class AdminOverview {
  final int days;
  final int users;
  final int requests;
  final int calls;
  final double reportedUsd;
  final int unknownCosts;
  final bool billingEnabled;
  final List<AdminDaily> daily;
  final List<AdminModel> models;
  final Map<String, int> mediaReservations;
  const AdminOverview({required this.days, required this.users,
    required this.requests, required this.calls, required this.reportedUsd,
    required this.unknownCosts, required this.billingEnabled,
    required this.daily, required this.models, required this.mediaReservations});

  static int _count(Object? value) => value is num && value >= 0 ? value.toInt() : 0;
  static double _amount(Object? value) => value is num && value.isFinite && value >= 0 ? value.toDouble() : 0;

  factory AdminOverview.fromJson(Map<String, dynamic> json) {
    final usage = json['provider_usage'];
    if (usage is! Map || json['daily'] is! List || usage['models'] is! List) {
      throw const AdminException('O backend enviou indicadores incompletos.');
    }
    final reserves = json['media_reservations'];
    final daily = <AdminDaily>[];
    for (final element in json['daily'] as List) {
      if (element is Map && element['day'] is String) {
        daily.add(AdminDaily(element['day'] as String, _count(element['requests'])));
      }
    }
    final models = <AdminModel>[];
    for (final element in usage['models'] as List) {
      if (element is Map) {
        models.add(AdminModel(
          '${element['model'] ?? 'desconhecido'}',
          '${element['category'] ?? 'outro'}', _count(element['calls']),
          _amount(element['reported_cost_usd']), _count(element['unknown_cost_calls']),
        ));
      }
    }
    models.sort((a, b) => b.reportedUsd.compareTo(a.reportedUsd));
    return AdminOverview(
      days: _count(json['period_days']),
      users: _count(json['active_users_in_period']),
      requests: _count(json['requests_total']),
      calls: _count(usage['llm_and_media_calls']),
      reportedUsd: _amount(usage['reported_cost_usd']),
      unknownCosts: _count(usage['unknown_cost_calls']),
      billingEnabled: json['billing_enabled'] == true,
      daily: List.unmodifiable(daily),
      models: List.unmodifiable(models),
      mediaReservations: {
        'image': reserves is Map ? _count(reserves['image']) : 0,
        'video': reserves is Map ? _count(reserves['video']) : 0,
      },
    );
  }
}

class AdminDaily {
  final String day;
  final int requests;
  const AdminDaily(this.day, this.requests);
}

class AdminModel {
  final String model;
  final String category;
  final int calls;
  final double reportedUsd;
  final int unknownCalls;
  const AdminModel(this.model, this.category, this.calls, this.reportedUsd, this.unknownCalls);
}

class AdminAccount {
  final String owner;
  final String plan;
  final String? expiresAt;
  final int balance;
  const AdminAccount(this.owner, this.plan, this.expiresAt, this.balance);
  factory AdminAccount.fromJson(Map<String, dynamic> json) {
    if (json['account_id'] is! String || json['plan'] is! String ||
        json['credits_balance'] is! int) {
      throw const AdminException('Dados comerciais inválidos.');
    }
    return AdminAccount(json['account_id'] as String, json['plan'] as String,
        json['plan_expires_at'] as String?, json['credits_balance'] as int);
  }
}
