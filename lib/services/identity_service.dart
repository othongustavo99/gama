import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// Identidade do usuário (dispositivo ou Google).
class IdentityService {
  IdentityService._();
  static final IdentityService instance = IdentityService._();

  static const _keyUserId = 'gama_user_id';
  static const _keyDisplayName = 'gama_display_name';
  static const _keyEmail = 'gama_email';
  static const _keyPhotoUrl = 'gama_photo_url';
  static const _keyLoggedIn = 'gama_logged_in';
  static const _keyProvider = 'gama_auth_provider'; // google | guest

  late SharedPreferences _prefs;
  bool _ready = false;

  Future<void> init() async {
    if (_ready) return;
    _prefs = await SharedPreferences.getInstance();
    _ready = true;
  }

  bool get isLoggedIn {
    if (!_ready) return false;
    return _prefs.getBool(_keyLoggedIn) ?? false;
  }

  String get userId {
    if (!_ready) return 'default';
    final id = _prefs.getString(_keyUserId);
    if (id == null || id.isEmpty) return 'default';
    return id;
  }

  String get displayName {
    if (!_ready) return 'Usuário';
    final n = _prefs.getString(_keyDisplayName);
    if (n != null && n.trim().isNotEmpty) return n.trim();
    final email = _prefs.getString(_keyEmail);
    if (email != null && email.contains('@')) {
      return email.split('@').first;
    }
    return 'Usuário';
  }

  String? get email => _ready ? _prefs.getString(_keyEmail) : null;
  String? get photoUrl => _ready ? _prefs.getString(_keyPhotoUrl) : null;
  String get provider =>
      _ready ? (_prefs.getString(_keyProvider) ?? 'guest') : 'guest';

  Future<void> setSession({
    required String userId,
    required String displayName,
    String? email,
    String? photoUrl,
    required String provider,
  }) async {
    await init();
    await _prefs.setString(_keyUserId, userId);
    await _prefs.setString(_keyDisplayName, displayName);
    await _prefs.setBool(_keyLoggedIn, true);
    await _prefs.setString(_keyProvider, provider);
    if (email != null) {
      await _prefs.setString(_keyEmail, email);
    } else {
      await _prefs.remove(_keyEmail);
    }
    if (photoUrl != null) {
      await _prefs.setString(_keyPhotoUrl, photoUrl);
    } else {
      await _prefs.remove(_keyPhotoUrl);
    }
  }

  Future<void> bindGoogleUser({
    required String googleId,
    String? name,
    String? email,
    String? photoUrl,
  }) async {
    final display = (name != null && name.trim().isNotEmpty)
        ? name.trim()
        : (email != null && email.contains('@')
              ? email.split('@').first
              : 'Usuário Google');
    await setSession(
      userId: 'google_$googleId',
      displayName: display,
      email: email,
      photoUrl: photoUrl,
      provider: 'google',
    );
  }

  /// Convidado (sem Google) — ainda tem id estável para memória.
  Future<void> continueAsGuest() async {
    await init();
    var id = _prefs.getString(_keyUserId);
    if (id == null || id.isEmpty || id == 'default') {
      id = 'device_${const Uuid().v4()}';
    }
    // se já era google, gera novo device id
    if (id.startsWith('google_')) {
      id = 'device_${const Uuid().v4()}';
    }
    await setSession(userId: id, displayName: 'Convidado', provider: 'guest');
  }

  Future<void> signOutLocal() async {
    await init();
    await _prefs.setBool(_keyLoggedIn, false);
    await _prefs.setString(_keyProvider, 'guest');
    await _prefs.remove(_keyEmail);
    await _prefs.remove(_keyPhotoUrl);
  }

  Future<void> clearAll() async {
    await init();
    await _prefs.remove(_keyUserId);
    await _prefs.remove(_keyDisplayName);
    await _prefs.remove(_keyEmail);
    await _prefs.remove(_keyPhotoUrl);
    await _prefs.setBool(_keyLoggedIn, false);
    await _prefs.remove(_keyProvider);
  }
}
