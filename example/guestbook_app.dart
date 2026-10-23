import 'dart:io';
import 'dart:typed_data';

import 'package:dart_apache/dart_apache.dart';

/// A classic server-rendered dynamic app — the "Laravel" side of Dartisan:
/// routing + Blaze views + request validation + CSRF + session flash + the data
/// layer. No JavaScript. Post a signed message; it's validated, stored, and the
/// page re-renders the list.
///
/// Run:
///   dart run example/guestbook_app.dart --root=./public --port=8080 --workers=1
///
/// (Use --workers=1 so the in-memory store is shared across requests in this
/// demo; a real deploy would use SqlDatabase for shared state.)

// Demo session key — replace with a secret in production.
final Uint8List _appKey =
    Uint8List.fromList(List<int>.generate(32, (i) => (i * 5 + 17) & 0xff));

DartApp buildApp(ServerConfig config) {
  final router = Router(
    views: BlazeEngine('example/guestbook_views', cache: false),
    sessions: SessionManager(_appKey, secure: false),
    maxBodyBytes: 64 * 1024,
  );
  router.singleton<InMemoryDatabase>((_) => InMemoryDatabase());
  router.use(verifyCsrf());

  router.get('/', (req) async {
    final db = req.make<InMemoryDatabase>();
    final entries =
        await db.table('entries').orderBy('id', descending: true).get();
    return req.view('guestbook', {
      'title': 'Guestbook',
      'entries': entries,
      'flash': req.session.flashed('status'),
      'error': null,
      'csrf': req.csrfToken(),
    });
  });

  router.post('/entries', (req) async {
    final db = req.make<InMemoryDatabase>();
    try {
      final data = await req.validate({
        'name': 'required|min:2|max:40',
        'message': 'required|min:2|max:280',
      });
      await db.table('entries').insert({
        'name': data['name'],
        'message': data['message'],
      });
      req.session.flash('status', 'Thanks for signing!');
      await req.redirect('/');
    } on ValidationException catch (e) {
      final entries =
          await db.table('entries').orderBy('id', descending: true).get();
      return req.view('guestbook', {
        'title': 'Guestbook',
        'entries': entries,
        'flash': null,
        'error': e.errors.values.first.first,
        'csrf': req.csrfToken(),
      });
    }
  });

  return router.toApp();
}

Future<void> main(List<String> arguments) async {
  final config = ServerConfig.fromArgs(arguments);
  final server = ServerSupervisor(config, appBuilder: buildApp);
  ProcessSignal.sigint.watch().listen((_) async {
    await server.stop();
    exit(0);
  });
  await server.start();
}
