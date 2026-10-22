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
  });
}
