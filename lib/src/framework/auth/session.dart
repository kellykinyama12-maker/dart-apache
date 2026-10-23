// Dartisan auth + sessions. Sessions are **stateless, encrypted cookies**: the
// whole session travels in an AES-GCM cookie, so nothing is stored server-side
// and it works unchanged across the worker-per-isolate model (no shared store).
// This is the Laravel `cookie` session-driver analog; `Auth` is a thin layer
// that keeps the logged-in user id in the session.
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// Issues and reads encrypted session cookies.
class SessionManager {
  SessionManager(
    this.key, {
    this.cookieName = 'dartisan_session',
    this.ttl = const Duration(hours: 2),
    this.secure = true,
  }) : assert(key.length == 32, 'session key must be 32 bytes (AES-256)');

  /// 32-byte AES key. Use a persistent key in production (see [generateKey]).
  final Uint8List key;
  final String cookieName;
  final Duration ttl;

  /// Adds `Secure` to the cookie (require HTTPS). Keep true in production.
  final bool secure;

  /// A fresh random 256-bit key. Persist it (e.g. from an env var) so sessions
  /// survive restarts and are shared across workers.
  static Uint8List generateKey() => _randomBytes(32);

  /// Loads the session from a request `Cookie` header (or a fresh empty one).
  Session load(String? cookieHeader) {
    final token = _readCookie(cookieHeader, cookieName);
    final payload = token == null ? null : _decrypt(token);
    final data = (payload?['d'] as Map?)?.cast<String, Object?>() ?? {};
    final flash = (payload?['f'] as Map?)?.cast<String, Object?>() ?? {};
    return Session(data, flash);
  }

  /// A `Set-Cookie` header value to persist [session], or null when nothing
  /// changed (so the response leaves the existing cookie untouched).
  String? setCookie(Session session) {
    if (!session.dirty) return null;
    final token = _encrypt({'d': session.all, 'f': session.nextFlash});
    final attrs = <String>[
      '$cookieName=$token',
      'Path=/',
      'HttpOnly',
      'SameSite=Lax',
      'Max-Age=${ttl.inSeconds}',
    ];
    if (secure) attrs.add('Secure');
    return attrs.join('; ');
  }

  // ---- crypto (AES-GCM: nonce(12) || ciphertext || tag) ----

  String _encrypt(Map<String, Object?> payload) {
    final exp = DateTime.now().add(ttl).millisecondsSinceEpoch;
    final bytes = utf8.encode(jsonEncode({'exp': exp, ...payload}));
    final nonce = _randomBytes(12);
    final gcm = GCMBlockCipher(AESEngine())
      ..init(true, AEADParameters(KeyParameter(key), 128, nonce, Uint8List(0)));
    final ct = gcm.process(Uint8List.fromList(bytes));
    final out = Uint8List(nonce.length + ct.length)
      ..setAll(0, nonce)
      ..setAll(nonce.length, ct);
    return base64Url.encode(out);
  }

  Map<String, Object?>? _decrypt(String token) {
    try {
      final raw = base64Url.decode(token);
      if (raw.length < 12 + 16) return null;
      final nonce = Uint8List.sublistView(raw, 0, 12);
      final ct = Uint8List.sublistView(raw, 12);
      final gcm = GCMBlockCipher(AESEngine())
        ..init(
            false, AEADParameters(KeyParameter(key), 128, nonce, Uint8List(0)));
      final pt = gcm.process(ct); // throws on tag mismatch
      final obj = (jsonDecode(utf8.decode(pt)) as Map).cast<String, Object?>();
      final exp = obj['exp'] as int?;
      if (exp == null || DateTime.now().millisecondsSinceEpoch > exp) {
        return null;
      }
      return obj;
    } on Object {
      return null;
    }
  }

  static String? _readCookie(String? header, String name) {
    if (header == null) return null;
    for (final pair in header.split(';')) {
      final i = pair.indexOf('=');
      if (i < 0) continue;
      if (pair.substring(0, i).trim() == name) return pair.substring(i + 1).trim();
    }
    return null;
  }

  static Uint8List _randomBytes(int n) {
    final r = Random.secure();
    return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
  }
}

/// A key/value session plus one-request flash storage. Mutations mark the
/// session dirty so a new cookie is written on the response.
class Session {
  Session(this._data, this._flash) : _dirty = _flash.isNotEmpty;

  final Map<String, Object?> _data;
  final Map<String, Object?> _flash; // readable this request only
  final Map<String, Object?> _nextFlash = {}; // persisted for the next request
  bool _dirty;

  bool get dirty => _dirty;
  Map<String, Object?> get all => Map<String, Object?>.of(_data);
  Map<String, Object?> get nextFlash => Map<String, Object?>.of(_nextFlash);

  Object? get(String key, [Object? fallback]) =>
      _data.containsKey(key) ? _data[key] : fallback;
  bool has(String key) => _data[key] != null;

  void put(String key, Object? value) {
    _data[key] = value;
    _dirty = true;
  }

  void forget(String key) {
    if (_data.remove(key) != null) _dirty = true;
  }

  void flush() {
    if (_data.isNotEmpty) {
      _data.clear();
      _dirty = true;
    }
  }

  /// Reads then removes [key].
  Object? pull(String key, [Object? fallback]) {
    final value = get(key, fallback);
    forget(key);
    return value;
  }

  /// Rotates per-session secrets (the CSRF token) on a privilege change, so any
  /// previously known token is invalidated (mitigates fixation/replay).
  void regenerate() {
    if (_data.remove('_csrf') != null) _dirty = true;
  }

  /// Stores [value] under [key] for the *next* request only.
  void flash(String key, Object? value) {
    _nextFlash[key] = value;
    _dirty = true;
  }

  /// Reads a value flashed by the previous request.
  Object? flashed(String key, [Object? fallback]) =>
      _flash.containsKey(key) ? _flash[key] : fallback;

  /// All values flashed by the previous request (a copy).
  Map<String, Object?> get flashBag => Map<String, Object?>.of(_flash);
}

/// Minimal authentication over a [Session]: it keeps the authenticated user id
/// under [idKey]. Pair with a user-lookup of your own for the full user object.
class Auth {
  Auth(this._session, {this.idKey = '_auth_id'});

  final Session _session;
  final String idKey;

  bool get check => _session.has(idKey);
  bool get guest => !check;
  Object? get id => _session.get(idKey);

  void login(Object userId) {
    _session.put(idKey, userId);
    _session.regenerate(); // rotate the CSRF token on privilege change
  }

  void logout() {
    _session.forget(idKey);
    _session.regenerate();
  }
}
