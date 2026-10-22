import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// Opaque, short-lived WebTransport session ticket.
///
/// WebTransport sends no cookies on its handshake, and JS cannot read an
/// HttpOnly session cookie — so the browser cannot forward the real session
/// over a WT stream. Instead the page fetches a ticket over normal HTTPS (where
/// the HttpOnly cookie *is* sent); the server AES-GCM-encrypts the `Cookie`
/// header plus an expiry into an opaque ticket. The client carries that ticket
/// on WT messages, and the bridge decrypts it to recover the session cookie —
/// keeping the cookie HttpOnly and server-side.
class WtTicket {
  WtTicket._();

  /// Encrypts [cookie] + an expiry under [key] (32 bytes), returning a
  /// URL-safe base64 token of `nonce(12) || ciphertext || tag`.
  static String issue(
    String cookie,
    Uint8List key, {
    Duration ttl = const Duration(minutes: 5),
  }) {
    final exp = DateTime.now().add(ttl).millisecondsSinceEpoch;
    final payload = utf8.encode(jsonEncode({'exp': exp, 'c': cookie}));
    final nonce = _randomBytes(12);
    final gcm = GCMBlockCipher(AESEngine())
      ..init(true, AEADParameters(KeyParameter(key), 128, nonce, Uint8List(0)));
    final ct = gcm.process(Uint8List.fromList(payload));
    final out = Uint8List(nonce.length + ct.length)
      ..setAll(0, nonce)
      ..setAll(nonce.length, ct);
    return base64Url.encode(out);
  }

  /// Decrypts and validates [ticket] under [key], returning the stored cookie
  /// string, or null when the ticket is malformed, tampered, or expired.
  static String? redeem(String ticket, Uint8List key) {
    try {
      final raw = base64Url.decode(ticket);
      if (raw.length < 12 + 16) return null; // nonce + GCM tag minimum
      final nonce = Uint8List.sublistView(raw, 0, 12);
      final ct = Uint8List.sublistView(raw, 12);
      final gcm = GCMBlockCipher(AESEngine())
        ..init(
          false,
          AEADParameters(KeyParameter(key), 128, nonce, Uint8List(0)),
        );
      final pt = gcm.process(ct); // throws on tag mismatch
      final obj = jsonDecode(utf8.decode(pt)) as Map<String, dynamic>;
      final exp = obj['exp'] as int;
      if (DateTime.now().millisecondsSinceEpoch > exp) return null;
      return obj['c'] as String?;
    } on Object {
      return null;
    }
  }

  static Uint8List _randomBytes(int n) {
    final r = Random.secure();
    return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
  }

  /// A fresh random 256-bit key for signing tickets.
  static Uint8List generateKey() => _randomBytes(32);
}
