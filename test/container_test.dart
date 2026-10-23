import 'package:dart_apache/dart_apache.dart';
import 'package:test/test.dart';

class Clock {
  Clock(this.label);
  final String label;
}

class Greeter {
  Greeter(this.clock);
  final Clock clock;
}

void main() {
  group('Container', () {
    test('bind resolves a fresh instance each make', () {
      final c = Container()..bind<Clock>((_) => Clock('t'));
      expect(identical(c.make<Clock>(), c.make<Clock>()), isFalse);
    });

    test('singleton builds once and caches', () {
      var built = 0;
      final c = Container()
        ..singleton<Clock>((_) {
          built++;
          return Clock('s');
        });
      final a = c.make<Clock>();
      final b = c.make<Clock>();
      expect(identical(a, b), isTrue);
      expect(built, 1);
    });

    test('instance registers an existing value', () {
      final clock = Clock('fixed');
      final c = Container()..instance<Clock>(clock);
      expect(identical(c.make<Clock>(), clock), isTrue);
    });

    test('factories can resolve dependencies from the container', () {
      final c = Container()
        ..singleton<Clock>((_) => Clock('dep'))
        ..bind<Greeter>((ct) => Greeter(ct.make<Clock>()));
      expect(c.make<Greeter>().clock.label, 'dep');
    });

    test('has reflects registration', () {
      final c = Container();
      expect(c.has<Clock>(), isFalse);
      c.bind<Clock>((_) => Clock('x'));
      expect(c.has<Clock>(), isTrue);
    });

    test('make throws when nothing is bound', () {
      expect(() => Container().make<Clock>(), throwsStateError);
    });
  });

  group('Router DI', () {
    test('services registered on the router resolve in handlers', () async {
      final router = Router()
        ..singleton<Clock>((_) => Clock('router'))
        ..get('/', (r) => r.text('clock=${r.make<Clock>().label}'));
      final app = router.toApp();
      final route = app.match('GET', '/')!;
      final ex = _FakeExchange('GET', Uri.parse('/'));
      await route.handler(ex, ex.response);
      expect(ex.response.text, 'clock=router');
    });
  });
}

class _FakeExchange implements ServerExchange {
  _FakeExchange(this.method, this.uri);
  @override
  final String method;
  @override
  final Uri uri;
  final _FakeResponse response = _FakeResponse();

  @override
  String get protocolVersion => '1.1';
  @override
  String get scheme => 'http';
  @override
  String get authority => 'localhost';
  @override
  String get protocol => 'http/1.1';
  @override
  String get remoteAddress => '127.0.0.1';
  @override
  int get remotePort => 1234;
  @override
  int get contentLength => 0;
  @override
  String? get contentType => null;
  @override
  void forEachHeader(void Function(String name, String value) action) {}
  @override
  Stream<List<int>> get body => const Stream<List<int>>.empty();
  @override
  ServerResponse respond() => response;
}

class _FakeResponse implements ServerResponse {
  int _status = 200;
  final Map<String, String> headers = {};
  final List<int> body = [];

  String get text => String.fromCharCodes(body);

  @override
  int get statusCode => _status;
  @override
  void setStatus(int statusCode, [String? reasonPhrase]) => _status = statusCode;
  @override
  void setHeader(String name, String value) => headers[name.toLowerCase()] = value;
  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      body.addAll(chunk);
    }
  }

  @override
  Future<void> close() async {}
}
