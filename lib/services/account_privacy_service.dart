import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/constants.dart';
import 'auth_service.dart';
import 'local_notification_service.dart';
import 'conversation_service.dart';
import 'identity_service.dart';
import 'settings_service.dart';

/// Endpoints protegidos por ID token Google, nunca por X-User-Id do cliente.
class AccountPrivacyService {
  AccountPrivacyService._();
  static final AccountPrivacyService instance = AccountPrivacyService._();

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 75),
    sendTimeout: const Duration(seconds: 30),
    validateStatus: (status) => status != null && status < 400,
  ));

  Future<Options> _options() async {
    if (IdentityService.instance.provider != 'google') {
      throw StateError('Entre com sua conta Google para gerenciar os dados.');
    }
    final token = await AuthService.instance.bearerToken();
    if (token == null || token.isEmpty) {
      throw StateError('Sessão expirada. Entre novamente com o Google.');
    }
    return Options(headers: {
      'Authorization': 'Bearer $token',
      ...AppConstants.authHeaders,
    });
  }

  Uri _url(String endpoint) {
    final base = SettingsService.instance.baseUrl.replaceFirst(RegExp(r'/+$'), '');
    return Uri.parse('$base/account$endpoint');
  }

  String _error(Object error) {
    if (error is DioException) {
      final body = error.response?.data;
      final detail = body is Map ? body['detail'] : null;
      if (detail is String && detail.isNotEmpty) return detail;
      if (detail is Map && detail['message'] is String) {
        return detail['message'] as String;
      }
      if (error.response?.statusCode == 401) return 'Sua sessão Google expirou. Entre novamente.';
      if (error.response?.statusCode == 503) return 'Servidor indisponível ou exclusão ainda em andamento. Tente novamente.';
      return 'Falha de conexão com o servidor (${error.response?.statusCode ?? 'rede'}).';
    }
    return error.toString();
  }

  Future<String> status() async {
    try {
      final response = await _dio.getUri<Map<String, dynamic>>(
        _url('/status'), options: await _options());
      return response.data?['status']?.toString() ?? 'unknown';
    } catch (error) {
      throw StateError(_error(error));
    }
  }

  Future<void> deleteAccount() async {
    try {
      final response = await _dio.deleteUri<Map<String, dynamic>>(
        _url(''), data: {'confirmation': 'EXCLUIR'}, options: await _options());
      if (response.data?['status'] != 'deleted' || response.data?['ok'] != true) {
        throw StateError('O servidor não confirmou a exclusão de todos os dados.');
      }
    } catch (error) {
      throw StateError(_error(error));
    }
  }

  Future<void> startNewAccount() async {
    try {
      final response = await _dio.postUri<Map<String, dynamic>>(
        _url('/start-new'), data: {'confirmation': 'RECOMEÇAR'},
        options: await _options());
      if (response.data?['status'] != 'active') {
        throw StateError('Não foi possível recomeçar esta conta.');
      }
    } catch (error) {
      throw StateError(_error(error));
    }
  }

  /// Só executar após o servidor confirmar a exclusão. A Biblioteca/Hive
  /// atuais são compartilhados no dispositivo, por isso a interface avisa que
  /// esses arquivos locais serão apagados mesmo se houve outras sessões.
  Future<void> clearDeviceAfterDeletion({bool keepGoogleSession = false}) async {
    final identity = IdentityService.instance;
    final savedUserId = identity.userId;
    final savedDisplayName = identity.displayName;
    final savedEmail = identity.email;
    final savedPhotoUrl = identity.photoUrl;
    final savedNumericId = identity.googleNumericId;
    // Cancelar agendamentos antes de apagar as preferências que os identificam.
    if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS) {
      try {
        await LocalNotificationService.instance.syncSavedReminders(enabled: false);
      } catch (_) {
        // Falha do plugin de notificações não pode impedir o apagamento do
        // histórico e dos arquivos. Lembretes externos podem exigir revisão.
      }
    }
    await ConversationService.instance.clearLocalForAccountDeletion();
    final docs = await getApplicationDocumentsDirectory();
    final library = Directory(p.join(docs.path, 'gama_library'));
    if (await library.exists()) await library.delete(recursive: true);
    // Downloads internos são privados do app. Arquivos exportados para pastas
    // externas de usuário (Downloads padrão) não podem ser apagados aqui.
    final internalDownloads = Directory(p.join(docs.path, 'GamaDownloads'));
    if (await internalDownloads.exists()) {
      await internalDownloads.delete(recursive: true);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    await identity.clearAll();
    if (keepGoogleSession && savedUserId.startsWith('google_')) {
      await identity.setSession(
        userId: savedUserId,
        displayName: savedDisplayName,
        email: savedEmail,
        photoUrl: savedPhotoUrl,
        provider: 'google',
        googleNumericId: savedNumericId,
      );
    }
  }
}
