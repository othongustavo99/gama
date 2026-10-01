import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';

import 'identity_service.dart';

/// Login com Google + sessão local.
class AuthService {
  AuthService._();
  static final AuthService instance = AuthService._();

  /// Opcional: Web client ID do Google Cloud (Android/iOS costumam precisar
  /// do SHA-1 no Firebase/Cloud Console). Deixe null se só usar o default.
  static const String? serverClientId =
    '387127501353-scoc2m2aao3r9283r8gnpk461n7a4b68.apps.googleusercontent.com';

final GoogleSignIn _google = GoogleSignIn(
  scopes: const ['email', 'profile'],
  serverClientId: serverClientId,
);

  Future<bool> signInWithGoogle() async {
    try {
      final account = await _google.signIn();
      if (account == null) {
        // usuário cancelou
        return false;
      }

      await IdentityService.instance.bindGoogleUser(
        googleId: account.id,
        name: account.displayName,
        email: account.email,
        photoUrl: account.photoUrl,
      );
      return true;
    } catch (e, st) {
      debugPrint('Google Sign-In error: $e');
      debugPrintStack(stackTrace: st);
      rethrow;
    }
  }

  Future<void> signOut() async {
    try {
      await _google.signOut();
    } catch (_) {}
    await IdentityService.instance.signOutLocal();
  }

  /// Tenta restaurar sessão Google silenciosamente (opcional).
  Future<bool> trySilentGoogle() async {
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
}
