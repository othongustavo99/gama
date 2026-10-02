import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import 'identity_service.dart';

/// Login Google multiplataforma.
///
/// - **Android / iOS:** plugin `google_sign_in` (client Android + SHA-1)
/// - **Windows / macOS / Linux:** OAuth no navegador (client **Desktop**)
class AuthService {
  AuthService._();
  static final AuthService instance = AuthService._();

  // ── Mobile: Web client ID (serverClientId) ─────────────────────────
  static const String? serverClientId = null;

  // ── Desktop: OAuth tipo "Aplicativo para computador" ───────────────
  // Google Cloud → Credenciais → Criar → OAuth → Desktop
  // Cole os valores aqui (obrigatório no Windows):
  static const String? desktopClientId =
      null; // 'SEU_ID.apps.googleusercontent.com'
  static const String? desktopClientSecret = null; // 'GOCSPX-...'

  final GoogleSignIn _google = GoogleSignIn(
    scopes: const ['email', 'profile'],
    serverClientId: serverClientId,
  );

  bool get isDesktop =>
      !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

  Future<bool> signInWithGoogle() async {
    if (isDesktop) return _signInDesktop();
    return _signInMobile();
  }

  Future<bool> _signInMobile() async {
    try {
      final account = await _google.signIn();
      if (account == null) return false;

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
        'Windows: configure desktopClientId e desktopClientSecret '
        'em lib/services/auth_service.dart\n'
        'Google Cloud → Credenciais → OAuth → tipo Desktop.',
      );
    }

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
      'access_type': 'online',
      'prompt': 'select_account',
    });

    final completer = Completer<String?>();

    server.listen((request) async {
      try {
        final q = request.uri.queryParameters;
        if (q['state'] != null && q['state'] != state) {
          request.response
            ..statusCode = 400
            ..headers.contentType = ContentType.html
            ..write(
              '<html><body>State inválido. Feche esta aba.</body></html>',
            );
          await request.response.close();
          if (!completer.isCompleted) completer.complete(null);
          return;
        }
        if (q['error'] != null) {
          request.response
            ..statusCode = 400
            ..headers.contentType = ContentType.html
            ..write(
              '<html><body>Erro: ${q['error']}. Feche esta aba.</body></html>',
            );
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
            '<h2 style="color:#FF6B00">Gamma</h2>'
            '<p>Login concluído. Pode fechar esta aba e voltar ao app.</p>'
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
      throw StateError('Não abriu o navegador. Verifique o padrão do sistema.');
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
    final accessToken = tokenJson['access_token'] as String?;
    if (accessToken == null) {
      throw StateError('Resposta sem access_token');
    }

    final userRes = await http.get(
      Uri.parse('https://www.googleapis.com/oauth2/v2/userinfo'),
      headers: {'Authorization': 'Bearer $accessToken'},
    );
    if (userRes.statusCode != 200) {
      throw StateError('Perfil Google: ${userRes.body}');
    }

    final user = jsonDecode(userRes.body) as Map<String, dynamic>;
    final id = user['id']?.toString();
    if (id == null || id.isEmpty) {
      throw StateError('Perfil sem id');
    }

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
      } catch (_) {}
    }
    await IdentityService.instance.signOutLocal();
  }

  Future<bool> trySilentGoogle() async {
    if (isDesktop) return IdentityService.instance.isLoggedIn;
    try {
      final account = await _google.signInSilently();
      if (account == null) return IdentityService.instance.isLoggedIn;
      await IdentityService.instance.bindGoogleUser(
        googleId: account.id,
        name: account.displayName,
        email: account.email,
        photoUrl: account.photoUrl,
      );
      return true;
    } catch (_) {
      return IdentityService.instance.isLoggedIn;
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
