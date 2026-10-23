import 'dart:io';
import 'dart:typed_data';

import 'package:dart_apache/dart_apache.dart';

/// Dartisan showcase — one small app that exercises the whole framework in a
/// single compiled binary: routing + middleware, Blaze views, request
/// validation, the data layer, encrypted-cookie sessions + auth, the service
/// container (DI), and a reactive Live component over WebTransport/HTTP3.
///
/// Run (HTTP/3 needs TLS; keep one worker so the in-memory notes + sessions are
/// consistent across requests in this demo):
///   dart run example/dartisan_app.dart --root=./public --port=8443 \
///     --http3 --wt-path=/wt --tls-cert=build/cert.pem --tls-key=build/key.pem \
///     --workers=1
///
/// Then open https://127.0.0.1:8443/ — log in with any name, add notes, and
/// click the Live counter (its state streams over WebTransport, no reload).

/// A reactive counter whose state round-trips to the client (see Dartisan Live).
class CounterComponent extends LiveComponent {
  @override
  String get name => 'counter';

  @override
  Map<String, Object?> initialState() => {'count': 0};

  @override
  Map<String, Object?> update(
    String action,
    Map<String, Object?> state,
    Map<String, Object?> payload,
  ) {
    final count = (state['count'] as num?)?.toInt() ?? 0;
    return switch (action) {
      'increment' => {'count': count + 1},
      'decrement' => {'count': count - 1},
      'reset' => {'count': 0},
      _ => state,
    };
  }

  @override
  String render(Map<String, Object?> state) =>
      '<p style="font-size:1.6rem">Count: '
      '<strong id="live-count">${state['count']}</strong></p>'
      '<button data-live-click="decrement">− 1</button> '
      '<button data-live-click="increment">+ 1</button> '
      '<button data-live-click="reset">reset</button>';
}

// A fixed demo key so cookies validate across workers/restarts. In a real app
// this comes from a secret (env var), never a hard-coded constant.
final Uint8List _demoKey =
    Uint8List.fromList(List<int>.generate(32, (i) => (i * 7 + 13) & 0xff));

/// Fired when a note is created; a listener queues a notification (I1 demo).
class NoteAdded {
  NoteAdded(this.owner, this.text);
  final String owner;
  final String text;
}

/// Top-level so it can cross the worker-isolate boundary.
DartApp buildApp(ServerConfig config) {
  final wtPath = config.wtPath ?? '/wt';
  final runtime = File('public/app/dartisan-live.js').readAsStringSync();
  final liveHtml =
      liveMount(CounterComponent(), wtPath: wtPath, inlineRuntime: runtime);

  final router = Router(
    views: BlazeEngine('example/dartisan_views', cache: false),
    sessions: SessionManager(_demoKey, secure: false),
    maxBodyBytes: 64 * 1024, // reject oversized form posts (J1)
    onError: (error, _) => stderr.writeln('[app] unhandled: $error'), // J4
  );

  // DI: a single in-memory store for this worker, resolved in handlers.
  router.singleton<InMemoryDatabase>((_) => InMemoryDatabase());

  // Application services, wired through the container (I1).
  final events = EventDispatcher();
  final queue = Queue(
    onFailed: (job, error, _) => stderr.writeln('[queue] job failed: $error'),
  );
  final mailer = Mailer(LogTransport(stdout.writeln));
  // Adding a note fires an event; its listener queues a notification off the
  // request path (event -> queue -> mail transport).
  events.listen<NoteAdded>((e) => mailer.queue(
        Message(
          to: '${e.owner}@example.test',
          subject: 'New note',
          text: 'You added: ${e.text}',
        ),
        queue,
      ));
  router.instance<EventDispatcher>(events);
  router.instance<Queue>(queue);
  router.instance<Mailer>(mailer);

  // CSRF-protect every unsafe (POST/PUT/PATCH/DELETE) request.
  router.use(verifyCsrf());

  // Reactive channel for the Live counter.
  router.wt = liveWtHandler(LiveRegistry()..register(CounterComponent()));

  router.get('/', (req) => req.view('home', {
        'title': 'Home',
        'auth': req.auth.check,
        'user': req.auth.id,
      }));

  // Login endpoints are rate-limited per client IP (J5).
  router.group('', () {
    router.get('/login', (req) => req.view('login', {
          'title': 'Log in',
          'auth': req.auth.check,
          'error': null,
          'old': '',
          'csrf': req.csrfToken(),
        }));

    router.post('/login', (req) async {
      try {
        final data = await req.validate({'name': 'required|min:2'});
        final name = data['name'].toString();
        req.auth.login(name);
        req.session.flash('status', 'Welcome, $name!');
        await req.redirect('/dashboard');
      } on ValidationException catch (e) {
        return req.view('login', {
          'title': 'Log in',
          'auth': req.auth.check,
          'error': e.errors.values.first.first,
          'old': req.query('name') ?? '',
          'csrf': req.csrfToken(),
        });
      }
    });
  }, middleware: [rateLimit(20, const Duration(minutes: 1))]);

  router.post('/logout', (req) async {
    req.auth.logout();
    return req.redirect('/');
  });

  // Everything in this group requires an authenticated session.
  router.group('', () {
    router.get('/dashboard', (req) async {
      final db = req.make<InMemoryDatabase>();
      final notes = await db.table('notes').where('owner', req.auth.id).get();
      return req.view('dashboard', {
        'title': 'Dashboard',
        'auth': true,
        'user': req.auth.id,
        'flash': req.session.flashed('status'),
        'notes': notes,
        'noteError': null,
        'live': liveHtml,
        'csrf': req.csrfToken(),
      });
    });

    router.post('/notes', (req) async {
      final db = req.make<InMemoryDatabase>();
      try {
        final data = await req.validate({'text': 'required|min:1'});
        final text = data['text'].toString();
        await db.table('notes').insert({'owner': req.auth.id, 'text': text});
        await req.events.dispatch(NoteAdded(req.auth.id.toString(), text));
        req.session.flash('status', 'Note added.');
        await req.redirect('/dashboard');
      } on ValidationException catch (e) {
        final notes = await db.table('notes').where('owner', req.auth.id).get();
        return req.view('dashboard', {
          'title': 'Dashboard',
          'auth': true,
          'user': req.auth.id,
          'flash': null,
          'notes': notes,
          'noteError': e.errors.values.first.first,
          'live': liveHtml,
          'csrf': req.csrfToken(),
        });
      }
    });
  }, middleware: [requireAuth(redirectTo: '/login')]);

  return router.toApp();
}

Future<void> main(List<String> arguments) async {
  final config = ServerConfig.fromArgs(arguments);
  if (!Directory(config.documentRoot).existsSync()) {
    stderr.writeln('DocumentRoot does not exist: ${config.documentRoot}');
    exitCode = 2;
    return;
  }
  final http3 = arguments.contains('--http3');
  final server = ServerSupervisor(
    config,
    kind: http3 ? WorkerKind.unified : WorkerKind.http1,
    appBuilder: buildApp,
  );
  ProcessSignal.sigint.watch().listen((_) async {
    await server.stop();
    exit(0);
  });
  await server.start();
}
