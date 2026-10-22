import 'dart:math';

import 'package:dart_apache/src/wt/ticket.dart';
import 'package:test/test.dart';
void main() {
  group('WtTicket', () {
    final key = WtTicket.generateKey();

    test('round-trips the cookie', () {
      const cookie = 'laravel_session=abc123; XSRF-TOKEN=xyz%3D%3D';
      final ticket = WtTicket.issue(cookie, key);
      expect(WtTicket.redeem(ticket, key), cookie);
    });

    test('rejects a ticket sealed with a different key', () {
      final ticket = WtTicket.issue('s=1', key);
      expect(WtTicket.redeem(ticket, WtTicket.generateKey()), isNull);
    });

    test('rejects a tampered ticket', () {
      final ticket = WtTicket.issue('s=1', key);
      final chars = ticket.split('');
      final i = ticket.length - 4; // in the ciphertext/tag region
      chars[i] = chars[i] == 'A' ? 'B' : 'A';
      expect(WtTicket.redeem(chars.join(), key), isNull);
    });

    test('rejects an expired ticket', () {
      final ticket = WtTicket.issue('s=1', key, ttl: const Duration(seconds: -10));
      expect(WtTicket.redeem(ticket, key), isNull);
    });

    test('rejects malformed input', () {
      expect(WtTicket.redeem('not-a-ticket!', key), isNull);
      expect(WtTicket.redeem('', key), isNull);
      expect(WtTicket.redeem('AAAA', key), isNull); // too short
    });

    test('fuzz: arbitrary and mutated tokens always return null, never throw',
        () {
      final rng = Random(0xA11CE);
      const alphabet =
          'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_=';
      // Random strings of varied length (valid and invalid base64url).
      for (var i = 0; i < 20000; i++) {
        final n = rng.nextInt(80);
        final s = String.fromCharCodes(
          List.generate(n, (_) => alphabet.codeUnitAt(rng.nextInt(64))),
        );
        expect(WtTicket.redeem(s, key), isNull);
      }
      // Bit-flip mutations of a *valid* ticket: tag check must reject all.
      final valid = WtTicket.issue('laravel_session=abc; XSRF-TOKEN=z', key);
      for (var i = 0; i < valid.length; i++) {
        final chars = valid.split('');
        final c = chars[i];
        chars[i] = c == 'A' ? 'B' : 'A';
        expect(WtTicket.redeem(chars.join(), key), isNull,
            reason: 'mutation at $i was accepted');
      }
    });
  });
}
