import 'package:dart_apache/src/client/alt_svc.dart';
import 'package:test/test.dart';

void main() {
  group('parseAltSvcH3', () {
    test('parses h3 with port-only authority using defaultHost', () {
      final alt = parseAltSvcH3('h3=":4433"; ma=86400', 'example.com');
      expect(alt, isNotNull);
      expect(alt!.host, 'example.com');
      expect(alt.port, 4433);
      expect(alt.isFresh, isTrue);
    });

    test('parses explicit host in authority', () {
      final alt = parseAltSvcH3('h3="h3.example.com:443"; ma=3600', 'origin');
      expect(alt!.host, 'h3.example.com');
      expect(alt.port, 443);
    });

    test('picks h3 among multiple alternatives, ignores drafts', () {
      final alt = parseAltSvcH3(
        'h3-29=":4433"; ma=3600, h3=":4433"; ma=86400',
        'host',
      );
      expect(alt!.port, 4433);
    });

    test('returns null when no h3 is advertised', () {
      expect(parseAltSvcH3('h2=":443"', 'host'), isNull);
    });

    test('returns null for clear', () {
      expect(parseAltSvcH3('clear', 'host'), isNull);
    });

    test('defaults max-age to 86400 when ma is absent', () {
      final before = DateTime.now().add(const Duration(seconds: 86000));
      final alt = parseAltSvcH3('h3=":4433"', 'host');
      expect(alt!.expiry.isAfter(before), isTrue);
    });
  });
}
