import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import 'identity_service.dart';
import 'settings_service.dart';
import '../core/constants.dart';
import '../core/launch_policy.dart';
import '../utils/error_logger.dart';
import '../utils/friendly_error.dart';

/// Login Google multiplataforma.
///
/// Credenciais via --dart-define (não commitar secrets):
///   GOOGLE_SERVER_CLIENT_ID
///   GOOGLE_DESKTOP_CLIENT_ID
///
/// userId gravado pelo IdentityService: google_email_<email-normalizado>.
/// O backend valida o Bearer e deriva a mesma identidade canônica.
class AuthService {
  AuthService._();
  static final AuthService instance = AuthService._();
  static const _desktopRefreshTokenKey = 'google_desktop_refresh_token';
  static const _desktopRefreshOwnerKey = 'google_desktop_refresh_owner';
  static const _desktopRefreshClientKey = 'google_desktop_refresh_client_id';
  static const _desktopRefreshBackendKey = 'google_desktop_refresh_backend';
  static const _desktopTokenPath = '/auth/google/desktop/token';
  static const _secureStorage = FlutterSecureStorage();

  static const String serverClientId = String.fromEnvironment(
    'GOOGLE_SERVER_CLIENT_ID',
    defaultValue: '', // Android: Web client ID, se usar
  );

  static const String desktopClientId = String.fromEnvironment(
    'GOOGLE_DESKTOP_CLIENT_ID',
    defaultValue: '',
  );

  late final GoogleSignIn _google = GoogleSignIn(
    scopes: const ['email', 'profile'],
    serverClientId: serverClientId.trim().isEmpty
        ? null
        : serverClientId.trim(),
  );

  bool get isDesktop =>
      !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

  String? _idToken;
  DateTime? _idTokenExpiry;

  /// ID token Google para o backend (`Authorization: Bearer`), com aud validável.
  /// Null = sem sessão válida; o chamador segue no modo legado ou pede login.
  Future<String?> bearerToken() async {
    // Nunca envie um token Google de uma sessão anterior ao atuar como
    // convidado (nem tente autenticação silenciosa nessa identidade).
    if (!IdentityService.instance.isLoggedIn ||
        IdentityService.instance.provider != 'google') {
      return null;
    }
    if (isDesktop) {
      final exp = _idTokenExpiry;
      if (_idToken != null &&
          exp != null &&
          DateTime.now().isBefore(exp.subtract(const Duration(minutes: 2)))) {
        return _idToken;
      }
      return _refreshDesktopIdToken();
    }
    if (_hasFreshCachedIdToken()) return _idToken;
    try {
      final account = _google.currentUser ?? await _google.signInSilently();
      final auth = await account?.authentication;
      final token = auth?.idToken;
      if (token == null || token.isEmpty) return null;
      _cacheIdToken(token);
      return token;
    } catch (e) {
      debugPrint('bearerToken: $e');
      return null;
    }
  }

  /// Renova uma sessão expirada após um 401. No desktop usa o refresh token
  /// protegido pelo armazenamento seguro do sistema; no mobile pede ao plugin
  /// Google uma sessão silenciosa atualizada.
  Future<String?> refreshBearerToken() async {
    if (!IdentityService.instance.isLoggedIn ||
        IdentityService.instance.provider != 'google') return null;
    if (isDesktop) return _refreshDesktopIdToken(force: true);
    try {
      final account = await _google.signInSilently(suppressErrors: false);
      final auth = await account?.authentication;
      final token = auth?.idToken;
      if (token == null || token.isEmpty) return null;
      _cacheIdToken(token);
      if (account != null) {
        await IdentityService.instance.bindGoogleUser(
          googleId: account.id,
          name: account.displayName,
          email: account.email,
          photoUrl: account.photoUrl,
        );
      }
      return token;
    } catch (e) {
      debugPrint('refreshBearerToken mobile: $e');
      return null;
    }
  }

  Uri _desktopTokenEndpoint() {
    final base = SettingsService.instance.baseUrl.trim().replaceFirst(RegExp(r'/+$'), '');
    final uri = Uri.tryParse('$base$_desktopTokenPath');
    final loopback = uri != null && {'localhost', '127.0.0.1', '::1'}.contains(uri.host);
    if (uri == null || uri.host.isEmpty || uri.userInfo.isNotEmpty ||
        uri.hasQuery || uri.hasFragment ||
        (uri.scheme != 'https' && !(uri.scheme == 'http' && loopback))) {
      throw const FriendlyActionException('Confira o endereço HTTPS do servidor da Gamma.');
    }
    return uri;
  }

  Future<http.Response> _requestDesktopTokens(Uri endpoint, Map<String, String> grant) async {
    final client = http.Client();
    try {
      final request = http.Request('POST', endpoint)
        ..followRedirects = false
        ..headers.addAll({
          ...AppConstants.authHeaders,
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        })
        ..body = jsonEncode(grant);
      return await client.send(request).then(http.Response.fromStream)
          .timeout(const Duration(seconds: 20));
    } finally {
      client.close();
    }
  }

  Map<String, dynamic> _desktopTokenBody(http.Response response) {
    try {
      final data = jsonDecode(response.body);
      if (data is Map<String, dynamic>) return data;
    } on FormatException {
      // Never include a token response in diagnostics or in the UI.
    }
    return const {};
  }

  String? _desktopErrorCode(Map<String, dynamic> data) {
    final detail = data['detail'];
    final code = detail is Map ? detail['code'] : null;
    return code is String ? code : null;
  }

  FriendlyActionException _desktopLoginError(http.Response response, Map<String, dynamic> data) {
    if (response.statusCode == 404) {
      return const FriendlyActionException(
        'O servidor da Gamma precisa ser atualizado para o login do Windows.',
      );
    }
    if (response.statusCode == 429) {
      return const FriendlyActionException('Aguarde um pouco antes de tentar entrar novamente.');
    }
    return switch (_desktopErrorCode(data)) {
      'desktop_oauth_unconfigured' => const FriendlyActionException(
        'O login do Windows precisa ser configurado no servidor da Gamma.',
      ),
      'desktop_oauth_client_mismatch' => const FriendlyActionException(
        'O ID do Google neste executável difere do ID Desktop configurado no servidor.',
      ),
      'desktop_oauth_grant_rejected' => const FriendlyActionException(
        'A autorização do Google expirou ou foi recusada. Inicie o login novamente.',
      ),
      _ => const FriendlyActionException('Não foi possível concluir o login com o Google. Tente de novo.'),
    };
  }

  Future<void> _clearDesktopRefreshToken() async {
    await _secureStorage.delete(key: _desktopRefreshTokenKey);
    await _secureStorage.delete(key: _desktopRefreshOwnerKey);
    await _secureStorage.delete(key: _desktopRefreshClientKey);
    await _secureStorage.delete(key: _desktopRefreshBackendKey);
  }

  Future<String?>? _desktopRefreshInFlight;

  Future<String?> _refreshDesktopIdToken({bool force = false}) async {
    if (!force && _hasFreshCachedIdToken()) return _idToken;
    final current = _desktopRefreshInFlight;
    if (current != null) return current;
    final request = _performDesktopRefresh();
    _desktopRefreshInFlight = request;
    try {
      return await request;
    } finally {
      _desktopRefreshInFlight = null;
    }
  }

  Future<String?> _performDesktopRefresh() async {
    try {
      final endpoint = _desktopTokenEndpoint();
      final owner = await _secureStorage.read(key: _desktopRefreshOwnerKey);
      final client = await _secureStorage.read(key: _desktopRefreshClientKey);
      final backend = await _secureStorage.read(key: _desktopRefreshBackendKey);
      final identity = IdentityService.instance;
      final clientId = desktopClientId.trim();
      bool sameOwner() =>
          owner != null && owner == identity.googleNumericId &&
          identity.isLoggedIn && identity.provider == 'google';
      // Legacy sessions without a stored backend can migrate to the official host.
      if (!sameOwner() || client != clientId ||
          endpoint.toString() != (backend ?? '${AppConstants.apiBaseUrl}$_desktopTokenPath')) {
        return null;
      }
      final refresh = await _secureStorage.read(key: _desktopRefreshTokenKey);
      if (refresh == null || refresh.isEmpty || !sameOwner()) return null;
      final response = await _requestDesktopTokens(endpoint, {
        'client_id': clientId,
        'grant_type': 'refresh_token',
        'refresh_token': refresh,
      });
      if (!sameOwner() || endpoint != _desktopTokenEndpoint()) return null;
      // A simultaneous sign-in can replace the stored token for the same user.
      if (await _secureStorage.read(key: _desktopRefreshTokenKey) != refresh) return null;
      final data = _desktopTokenBody(response);
      if (response.statusCode != 200) {
        if (_desktopErrorCode(data) == 'desktop_oauth_grant_rejected') {
          await _clearDesktopRefreshToken();
          _idToken = null;
          _idTokenExpiry = null;
        }
        return null;
      }
      final token = data['id_token'];
      if (token is! String || token.isEmpty) return null;
      final rotated = data['refresh_token'];
      if (rotated is String && rotated.isNotEmpty && rotated != refresh) {
        await _secureStorage.write(key: _desktopRefreshTokenKey, value: rotated);
      }
      if (backend == null) {
        await _secureStorage.write(key: _desktopRefreshBackendKey, value: endpoint.toString());
      }
      _cacheIdToken(token);
      return token;
    } catch (error, stack) {
      logSwallowed(error, stack, context: 'renovar login Google no Windows');
      return null;
    }
  }

  bool _hasFreshCachedIdToken() =>
      _idToken != null &&
      _idTokenExpiry != null &&
      DateTime.now().isBefore(
        _idTokenExpiry!.subtract(const Duration(minutes: 2)),
      );

  void _cacheIdToken(String token) {
    _idToken = token;
    var expiry = DateTime.now().add(const Duration(minutes: 55));
    try {
      final parts = token.split('.');
      if (parts.length == 3) {
        final payload = jsonDecode(
          utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
        );
        if (payload is Map && payload['exp'] is num) {
          expiry = DateTime.fromMillisecondsSinceEpoch(
            (payload['exp'] as num).toInt() * 1000,
            isUtc: true,
          ).toLocal();
        }
      }
    } catch (error, stack) {
      logSwallowed(error, stack);
      // Tokens válidos continuam utilizáveis por até 55 min se não der para
      // ler o exp localmente; o servidor segue sendo quem valida a assinatura.
    }
    _idTokenExpiry = expiry;
  }

  Future<bool> signInWithGoogle() async {
    if (isDesktop) return _signInDesktop();
    return _signInMobile();
  }

  Future<bool> _signInMobile() async {
    try {
      if (serverClientId.trim().isEmpty) {
        throw StateError(
          'GOOGLE_SERVER_CLIENT_ID não foi configurado. Use o ID OAuth de '
          'cliente Web do Google Cloud ao compilar o app.',
        );
      }
      final account = await _google.signIn();
      if (account == null) return false;

      final authentication = await account.authentication;
      final idToken = authentication.idToken;
      if (idToken == null || idToken.isEmpty) {
        throw StateError(
          'O Google concluiu o login, mas não retornou um ID token. '
          'Confira se GOOGLE_SERVER_CLIENT_ID é o OAuth de cliente Web e '
          'se o mesmo ID está em GOOGLE_OAUTH_CLIENT_IDS no servidor.',
        );
      }
      _cacheIdToken(idToken);

      await IdentityService.instance.bindGoogleUser(
        googleId: account.id,
        name: account.displayName,
        email: account.email,
        photoUrl: account.photoUrl,
      );
      return true;
    } catch (e, st) {
      debugPrint('Google Sign-In mobile: $e');
      debugPrintStack(stackTrace: st);
      rethrow;
    }
  }

  Future<bool> _signInDesktop() async {
    final clientId = desktopClientId.trim();

    if (clientId.isEmpty) {
      throw const FriendlyActionException(
        'Este executável precisa ser gerado com o ID OAuth Desktop do Google.',
      );
    }

    final endpoint = _desktopTokenEndpoint();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final redirectUri = 'http://127.0.0.1:${server.port}/';
    final state = _randomString(32);
    final codeVerifier = _randomString(64);
    final codeChallenge = base64Url
        .encode(sha256.convert(utf8.encode(codeVerifier)).bytes)
        .replaceAll('=', '');

    final authUri = Uri.https('accounts.google.com', '/o/oauth2/v2/auth', {
      'client_id': clientId,
      'redirect_uri': redirectUri,
      'response_type': 'code',
      'scope': 'openid email profile',
      'state': state,
      'code_challenge': codeChallenge,
      'code_challenge_method': 'S256',
      'access_type': 'offline',
      'prompt': 'select_account consent',
    });

    final completer = Completer<String?>();

    server.listen((request) async {
      try {
        final q = request.uri.queryParameters;
        if (request.method != 'GET' || request.uri.path != '/' ||
            q['state'] != state) {
          request.response
            ..statusCode = 400
            ..headers.contentType = ContentType.html
            ..write('<html><body>State inválido.</body></html>');
          await request.response.close();
          return;
        }
        if (q['error'] != null) {
          request.response
            ..statusCode = 400
            ..headers.contentType = ContentType.html
            ..write('<html><body>O Google nao autorizou o login.</body></html>');
          await request.response.close();
          if (!completer.isCompleted) completer.complete(null);
          return;
        }
        final code = q['code'];
        if (code == null || code.isEmpty) {
          request.response
            ..statusCode = 400
            ..write('Codigo de autorizacao ausente');
          await request.response.close();
          if (!completer.isCompleted) completer.complete(null);
          return;
        }
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType.html
          ..write(
            '<!DOCTYPE html><html><body style="font-family:system-ui;text-align:center;padding:48px">'
            '<h2 style="color:#FF6B00">$kAppName</h2>'
            '<p>Autorização recebida. Volte ao app para concluir o login.</p>'
            '</body></html>',
          );
        await request.response.close();
        if (!completer.isCompleted) completer.complete(code);
      } catch (e) {
        if (!completer.isCompleted) completer.completeError(e);
      } finally {
        // Callback externo inválido não pode encerrar o listener legítimo.
        if (completer.isCompleted) await server.close(force: true);
      }
    });

    final String? code;
    try {
      final opened = await launchUrl(authUri, mode: LaunchMode.externalApplication);
      if (!opened) {
        throw const FriendlyActionException('Não foi possível abrir o navegador para entrar com o Google.');
      }
      code = await completer.future.timeout(const Duration(minutes: 3));
    } finally {
      await server.close(force: true);
    }

    if (code == null || code.isEmpty) return false;

    final tokenRes = await _requestDesktopTokens(endpoint, {
      'code': code,
      'client_id': clientId,
      'redirect_uri': redirectUri,
      'grant_type': 'authorization_code',
      'code_verifier': codeVerifier,
    });
    final tokens = _desktopTokenBody(tokenRes);
    if (tokenRes.statusCode != 200) throw _desktopLoginError(tokenRes, tokens);
    final refreshToken = tokens['refresh_token']?.toString();
    final idToken = tokens['id_token'];
    final accessToken = tokens['access_token'];
    if (idToken is! String || idToken.isEmpty ||
        accessToken is! String || accessToken.isEmpty) {
      throw const FriendlyActionException('O servidor não retornou a sessão do Google. Tente de novo.');
    }

    final userRes = await http.get(
      Uri.parse('https://www.googleapis.com/oauth2/v2/userinfo'),
      headers: {'Authorization': 'Bearer $accessToken'},
    );
    if (userRes.statusCode != 200) {
      throw StateError('Não consegui consultar o perfil Google (HTTP ${userRes.statusCode}).');
    }

    final user = jsonDecode(userRes.body) as Map<String, dynamic>;
    final id = user['id']?.toString();
    if (id == null || id.isEmpty) throw StateError('Perfil sem id');

    await IdentityService.instance.bindGoogleUser(
      googleId: id,
      name: user['name']?.toString(),
      email: user['email']?.toString(),
      photoUrl: user['picture']?.toString(),
    );
    _cacheIdToken(idToken);
    // Só vincular o token de renovação após conhecer a identidade que
    // realmente concluiu o login. Troca de Google invalida a sessão anterior.
    try {
      final existingOwner = await _secureStorage.read(key: _desktopRefreshOwnerKey);
      final existingClient = await _secureStorage.read(key: _desktopRefreshClientKey);
      final existingBackend = await _secureStorage.read(key: _desktopRefreshBackendKey);
      if (existingOwner != id || existingClient != clientId || existingBackend != endpoint.toString()) {
        await _clearDesktopRefreshToken();
      }
      if (refreshToken != null && refreshToken.isNotEmpty) {
        await _secureStorage.write(key: _desktopRefreshTokenKey, value: refreshToken);
      }
      await _secureStorage.write(key: _desktopRefreshOwnerKey, value: id);
      await _secureStorage.write(key: _desktopRefreshClientKey, value: clientId);
      await _secureStorage.write(key: _desktopRefreshBackendKey, value: endpoint.toString());
    } catch (e) {
      // A sessão atual funciona mesmo se o Windows não persistir o token.
      debugPrint('Não foi possível persistir a sessão: $e');
    }
    return true;
  }

  Future<void> signOut() async {
    if (!isDesktop) {
      try {
        await _google.signOut();
      } catch (error, stack) {
        logSwallowed(error, stack);
      }
    }
    // Não mantenha um token válido em memória depois do logout.
    _idToken = null;
    _idTokenExpiry = null;
    if (isDesktop) {
      try {
        await _clearDesktopRefreshToken();
      } catch (e) {
        debugPrint('secure storage delete: $e');
      }
    }
    await IdentityService.instance.signOutLocal();
  }

  Future<bool> trySilentGoogle() async {
    // Sessões convidadas só entram em builds de desenvolvimento autorizados.
    // Builds comerciais sempre apresentam o login Google novamente.
    if (IdentityService.instance.provider != 'google') {
      return GamaLaunchPolicy.guestLoginEnabled &&
          IdentityService.instance.isLoggedIn;
    }
    if (isDesktop) return (await bearerToken()) != null;
    try {
      final account = await _google.signInSilently(suppressErrors: false);
      if (account == null) return false;
      final idToken = (await account.authentication).idToken;
      if (idToken == null || idToken.isEmpty) return false;
      _cacheIdToken(idToken);
      await IdentityService.instance.bindGoogleUser(
        googleId: account.id,
        name: account.displayName,
        email: account.email,
        photoUrl: account.photoUrl,
      );
      return true;
    } catch (error, stack) {
      logSwallowed(error, stack);
      return false;
    }
  }

  static String _randomString(int length) {
    const chars =
        'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~';
    final rnd = Random.secure();
    return List.generate(
      length,
      (_) => chars[rnd.nextInt(chars.length)],
    ).join();
  }
}
