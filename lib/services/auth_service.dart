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
import '../utils/error_logger.dart';

/// Login Google multiplataforma.
///
/// Credenciais via --dart-define (não commitar secrets):
///   GOOGLE_SERVER_CLIENT_ID
///   GOOGLE_DESKTOP_CLIENT_ID
///   GOOGLE_DESKTOP_CLIENT_SECRET
///
/// userId gravado pelo IdentityService: google_email_<email-normalizado>.
/// O backend valida o Bearer e deriva a mesma identidade canônica.
class AuthService {
  AuthService._();
  static final AuthService instance = AuthService._();
  static const _desktopRefreshTokenKey = 'google_desktop_refresh_token';
  static const _secureStorage = FlutterSecureStorage();

  static const String serverClientId = String.fromEnvironment(
    'GOOGLE_SERVER_CLIENT_ID',
    defaultValue: '', // Android: Web client ID, se usar
  );

  static const String desktopClientId = String.fromEnvironment(
    'GOOGLE_DESKTOP_CLIENT_ID',
    defaultValue: '',
  );

  static const String desktopClientSecret = String.fromEnvironment(
    'GOOGLE_DESKTOP_CLIENT_SECRET',
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

  Future<String?> _refreshDesktopIdToken({bool force = false}) async {
    if (!force &&
        _idToken != null &&
        _idTokenExpiry != null &&
        DateTime.now().isBefore(
          _idTokenExpiry!.subtract(const Duration(minutes: 2)),
        )) {
      return _idToken;
    }
    try {
      final refreshToken = await _secureStorage.read(
        key: _desktopRefreshTokenKey,
      );
      if (refreshToken == null || refreshToken.isEmpty) return null;
      final body = <String, String>{
        'client_id': desktopClientId,
        'grant_type': 'refresh_token',
        'refresh_token': refreshToken,
      };
      final secret = desktopClientSecret.trim();
      if (secret.isNotEmpty) body['client_secret'] = secret;
      final response = await http.post(
        Uri.parse('https://oauth2.googleapis.com/token'),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: body,
      );
      if (response.statusCode != 200) {
        if (response.statusCode == 400 || response.statusCode == 401) {
          await _secureStorage.delete(key: _desktopRefreshTokenKey);
          _idToken = null;
          _idTokenExpiry = null;
        }
        return null;
      }
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final token = json['id_token']?.toString();
      if (token == null || token.isEmpty) return null;
      final expiresIn = (json['expires_in'] as num?)?.toInt() ?? 3600;
      _idToken = token;
      _idTokenExpiry = DateTime.now().add(Duration(seconds: expiresIn));
      return token;
    } catch (e) {
      debugPrint('refreshBearerToken desktop: $e');
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
    final clientId = desktopClientId?.trim();
    final clientSecret = desktopClientSecret?.trim();

    if (clientId == null || clientId.isEmpty) {
      throw StateError(
        'Windows: passe --dart-define=GOOGLE_DESKTOP_CLIENT_ID=...\n'
        'e GOOGLE_DESKTOP_CLIENT_SECRET=... (OAuth tipo Desktop no Google Cloud).',
      );
    }

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final redirectUri = 'http://127.0.0.1:${server.port}/';
    final state = _randomString(32);
    final codeVerifier = _randomString(64);
    final codeChallenge = base64Url
        .encode(sha256.convert(utf8.encode(codeVerifier)).bytes)
        .replaceAll('=', '');

    String? existingRefreshToken;
    try {
      existingRefreshToken = await _secureStorage.read(
        key: _desktopRefreshTokenKey,
      );
    } catch (e) {
      debugPrint('secure storage read: $e');
    }
    final authUri = Uri.https('accounts.google.com', '/o/oauth2/v2/auth', {
      'client_id': clientId,
      'redirect_uri': redirectUri,
      'response_type': 'code',
      'scope': 'openid email profile',
      'state': state,
      'code_challenge': codeChallenge,
      'code_challenge_method': 'S256',
      'access_type': 'offline',
      'prompt': existingRefreshToken == null || existingRefreshToken.isEmpty
          ? 'select_account consent'
          : 'select_account',
    });

    final completer = Completer<String?>();

    server.listen((request) async {
      try {
        final q = request.uri.queryParameters;
        if (q['state'] != null && q['state'] != state) {
          request.response
            ..statusCode = 400
            ..headers.contentType = ContentType.html
            ..write('<html><body>State inválido.</body></html>');
          await request.response.close();
          if (!completer.isCompleted) completer.complete(null);
          return;
        }
        if (q['error'] != null) {
          request.response
            ..statusCode = 400
            ..headers.contentType = ContentType.html
            ..write('<html><body>Erro: ${q['error']}</body></html>');
          await request.response.close();
          if (!completer.isCompleted) completer.complete(null);
          return;
        }
        final code = q['code'];
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType.html
          ..write(
            '<!DOCTYPE html><html><body style="font-family:system-ui;text-align:center;padding:48px">'
            '<h2 style="color:#FF6B00">Gama</h2>'
            '<p>Login concluído. Pode fechar e voltar ao app.</p>'
            '</body></html>',
          );
        await request.response.close();
        if (!completer.isCompleted) completer.complete(code);
      } catch (e) {
        if (!completer.isCompleted) completer.completeError(e);
      } finally {
        await server.close(force: true);
      }
    });

    final ok = await launchUrl(authUri, mode: LaunchMode.externalApplication);
    if (!ok) {
      await server.close(force: true);
      throw StateError('Não abriu o navegador');
    }

    final code = await completer.future.timeout(
      const Duration(minutes: 3),
      onTimeout: () async {
        await server.close(force: true);
        return null;
      },
    );

    if (code == null || code.isEmpty) return false;

    final body = <String, String>{
      'code': code,
      'client_id': clientId,
      'redirect_uri': redirectUri,
      'grant_type': 'authorization_code',
      'code_verifier': codeVerifier,
    };
    if (clientSecret != null && clientSecret.isNotEmpty) {
      body['client_secret'] = clientSecret;
    }

    final tokenRes = await http.post(
      Uri.parse('https://oauth2.googleapis.com/token'),
      headers: {'Content-Type': 'application/x-www-form-urlencoded'},
      body: body,
    );
    if (tokenRes.statusCode != 200) {
      throw StateError(
        'Token Google (${tokenRes.statusCode}): ${tokenRes.body}',
      );
    }

    final tokenJson = jsonDecode(tokenRes.body) as Map<String, dynamic>;
    final refreshToken = tokenJson['refresh_token']?.toString();
    if (refreshToken != null && refreshToken.isNotEmpty) {
      try {
        await _secureStorage.write(
          key: _desktopRefreshTokenKey,
          value: refreshToken,
        );
      } catch (e) {
        debugPrint('secure storage write: $e');
      }
    }
    final idToken = tokenJson['id_token'] as String?;
    if (idToken == null || idToken.isEmpty) {
      throw StateError(
        'O Google não retornou ID token. Confira o escopo openid e o client ID OAuth.',
      );
    }
    final expiresIn = (tokenJson['expires_in'] as num?)?.toInt() ?? 3600;
    _idToken = idToken;
    _idTokenExpiry = DateTime.now().add(Duration(seconds: expiresIn));

    final userRes = await http.get(
      Uri.parse('https://www.googleapis.com/oauth2/v2/userinfo'),
      headers: {'Authorization': 'Bearer ${tokenJson['access_token']}'},
    );
    if (userRes.statusCode != 200) {
      throw StateError('Perfil Google: ${userRes.body}');
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
        await _secureStorage.delete(key: _desktopRefreshTokenKey);
      } catch (e) {
        debugPrint('secure storage delete: $e');
      }
    }
    await IdentityService.instance.signOutLocal();
  }

  Future<bool> trySilentGoogle() async {
    // Sessões convidadas permanecem locais e não tentam sincronização remota.
    if (IdentityService.instance.provider != 'google') {
      return IdentityService.instance.isLoggedIn;
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
