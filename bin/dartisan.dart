import 'dart:io';

import 'package:dart_apache/src/framework/cli/scaffold.dart';

/// `dartisan` — the Dartisan project/scaffolding CLI (the Artisan analog).
///
///   dartisan new myapp
///   dartisan make:controller User
///   dartisan make:component Counter
///   dartisan make:view profile
///   dartisan serve [entrypoint] [-- server args]
Future<void> main(List<String> args) async {
  if (args.isEmpty || args.first == 'help' || args.first == '--help') {
    _usage();
    return;
  }
  final cmd = args.first;
  final rest = args.skip(1).toList();
  switch (cmd) {
    case 'new':
      _new(rest);
    case 'make:controller':
      _make('controllers', rest, controllerSource, suffix: '_controller');
    case 'make:component':
      _makeComponent(rest);
    case 'make:model':
      _makeModel(rest);
    case 'make:migration':
      _makeMigration(rest);
    case 'make:middleware':
      _make('middleware', rest, middlewareSource, suffix: '');
    case 'make:view':
      _makeView(rest);
    case 'migrate':
      await _migrate(rest);
    case 'routes':
      await _routes(rest);
    case 'serve':
      await _serve(rest);
    default:
      stderr.writeln('Unknown command: $cmd\n');
      _usage();
      exitCode = 2;
  }
}

void _new(List<String> rest) {
  if (rest.isEmpty) {
    stderr.writeln('usage: dartisan new <name>');
    exitCode = 2;
    return;
  }
  final name = rest.first;
  final dir = Directory(name);
  if (dir.existsSync()) {
    stderr.writeln('Directory "$name" already exists.');
    exitCode = 2;
    return;
  }
  newProjectFiles(name, dartApachePath: _dartApachePath()).forEach((rel, content) {
    final f = File('$name/$rel');
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(content.trimLeft());
    stdout.writeln('  created $name/$rel');
  });
  stdout.writeln('\nCreated "$name". Next:\n  cd $name && dart pub get && dartisan serve');
}

// Resolves the absolute path to this dart-apache checkout so a scaffolded app's
// path dependency works no matter where the app is created.
String _dartApachePath() {
  try {
    final self = File.fromUri(Platform.script); // .../dart-apache/bin/dartisan.dart
    final root = self.parent.parent;
    if (File('${root.path}/pubspec.yaml').existsSync()) {
      return root.path.replaceAll(r'\', '/');
    }
  } on Object {
    // fall through to the relative default
  }
  return '../dart-apache';
}

void _make(
  String folder,
  List<String> rest,
  String Function(String) gen, {
  required String suffix,
}) {
  if (rest.isEmpty) {
    stderr.writeln('usage: dartisan make:... <Name>');
    exitCode = 2;
    return;
  }
  final name = rest.first;
  final path = '$folder/${snakeCase(name)}$suffix.dart';
  _write(path, gen(name));
}

void _makeView(List<String> rest) {
  if (rest.isEmpty) {
    stderr.writeln('usage: dartisan make:view <name>');
    exitCode = 2;
    return;
  }
  _write('views/${snakeCase(rest.first)}.blaze.html', viewSource(rest.first));
}

void _makeComponent(List<String> rest) {
  // `--view` scaffolds a Blaze view component; otherwise a Live component.
  final view = rest.contains('--view');
  final args = rest.where((a) => a != '--view').toList();
  if (args.isEmpty) {
    stderr.writeln('usage: dartisan make:component <Name> [--view]');
    exitCode = 2;
    return;
  }
  final name = args.first;
  if (view) {
    _write('views/components/${snakeCase(name)}.blaze.html',
        viewComponentSource(name));
  } else {
    _write('components/${snakeCase(name)}_component.dart', componentSource(name));
  }
}

void _makeModel(List<String> rest) {
  if (rest.isEmpty) {
    stderr.writeln('usage: dartisan make:model <Name> [field:type ...]');
    exitCode = 2;
    return;
  }
  final name = rest.first;
  final fields = parseFields(rest.skip(1));
  _write('models/${snakeCase(name)}.dart', modelSource(name, fields: fields));
}

void _makeMigration(List<String> rest) {
  if (rest.isEmpty) {
    stderr.writeln(
        'usage: dartisan make:migration <Name> [table:posts] [field:type ...]');
    exitCode = 2;
    return;
  }
  final name = rest.first;
  final specs = rest.skip(1).toList();
  final table = _specValue(specs, 'table') ?? tableFromMigrationName(name);
  final fields = parseFields(specs);
  final migrationName = '${_timestamp()}_${snakeCase(name)}';
  _write('migrations/$migrationName.dart',
      migrationSource(pascalCase(name), migrationName, table: table, fields: fields));
}

/// `dartisan migrate [--db=host:port] [--rollback]` — discovers
/// `migrations/*.dart`, generates a throwaway runner that imports them in
/// timestamp order and runs `Migrator.migrate()` (or `rollback()`).
Future<void> _migrate(List<String> rest) async {
  final dir = Directory('migrations');
  if (!dir.existsSync()) {
    stderr.writeln('No migrations/ directory. Create one with '
        'dartisan make:migration <Name>.');
    exitCode = 2;
    return;
  }
  var db = '127.0.0.1:4599';
  for (final a in rest) {
    if (a.startsWith('--db=')) db = a.substring(5);
  }
  final rollback = rest.contains('--rollback');
  final host = db.contains(':') ? db.substring(0, db.indexOf(':')) : db;
  final port = db.contains(':') ? int.parse(db.substring(db.indexOf(':') + 1)) : 4599;

  final files = dir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart') && !f.path.contains('_dartisan_'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  final classRe = RegExp(r'class\s+(\w+)\s+implements\s+Migration');
  final imports = <String>[];
  final classes = <String>[];
  for (final f in files) {
    final m = classRe.firstMatch(f.readAsStringSync());
    if (m == null) continue;
    imports.add("import '${f.uri.pathSegments.last}';");
    classes.add('${m.group(1)}()');
  }
  if (classes.isEmpty) {
    stdout.writeln('No migrations found in migrations/.');
    return;
  }

  final runner = File('migrations/_dartisan_migrate.dart');
  runner.writeAsStringSync('''
// GENERATED by `dartisan migrate` — safe to delete.
import 'package:dart_apache/dart_apache.dart';
${imports.join('\n')}

Future<void> main() async {
  final db = SqlDatabase(host: '$host', port: $port);
  final migrator = Migrator(db, [${classes.join(', ')}]);
  final names = await migrator.${rollback ? 'rollback' : 'migrate'}();
  print(names.isEmpty
      ? 'Nothing to ${rollback ? 'roll back' : 'migrate'}.'
      : '${rollback ? 'Rolled back' : 'Migrated'}: \${names.join(', ')}');
  await db.close();
}
''');
  try {
    final proc = await Process.start('dart', ['run', runner.path],
        mode: ProcessStartMode.inheritStdio);
    exitCode = await proc.exitCode;
  } finally {
    if (runner.existsSync()) runner.deleteSync();
  }
}

String? _specValue(List<String> specs, String key) {
  for (final s in specs) {
    final i = s.indexOf(':');
    if (i > 0 && s.substring(0, i) == key) return s.substring(i + 1);
  }
  return null;
}

String _timestamp() {
  final n = DateTime.now();
  String p(int v) => v.toString().padLeft(2, '0');
  return '${n.year}${p(n.month)}${p(n.day)}${p(n.hour)}${p(n.minute)}${p(n.second)}';
}

void _write(String path, String content) {
  final f = File(path);
  if (f.existsSync()) {
    stderr.writeln('$path already exists.');
    exitCode = 2;
    return;
  }
  f.parent.createSync(recursive: true);
  f.writeAsStringSync(content.trimLeft());
  stdout.writeln('created $path');
}

/// `dartisan routes [entry]` — lists an app's routes (method + pattern) by
/// loading its `buildApp` and walking `DartApp.routes`.
Future<void> _routes(List<String> rest) async {
  final entry = rest.firstWhere((a) => !a.startsWith('-'),
      orElse: () => _defaultEntry());
  if (entry.isEmpty || !File(entry).existsSync()) {
    stderr.writeln('No entrypoint found. Pass one: dartisan routes bin/app.dart');
    exitCode = 2;
    return;
  }
  final runner = File('bin/_dartisan_routes.dart');
  runner.writeAsStringSync('''
// GENERATED by `dartisan routes` — safe to delete.
import 'package:dart_apache/dart_apache.dart';
import '${entry.split('/').last}' as app;

void main() {
  final a = app.buildApp(ServerConfig.fromArgs(const ['--root=.']));
  for (final r in a.routes) {
    final methods = (r.methods == null || r.methods!.isEmpty)
        ? 'ANY'
        : r.methods!.join(',');
    print('\${methods.padRight(10)} \${r.pattern}');
  }
}
''');
  try {
    final proc = await Process.start('dart', ['run', runner.path],
        mode: ProcessStartMode.inheritStdio);
    exitCode = await proc.exitCode;
  } finally {
    if (runner.existsSync()) runner.deleteSync();
  }
}

Future<void> _serve(List<String> rest) async {
  // Entry point: first non-flag arg, else bin/<pkg>.dart or bin/main.dart.
  final entry = rest.firstWhere((a) => !a.startsWith('-'),
      orElse: () => _defaultEntry());
  if (entry.isEmpty) {
    stderr.writeln('No entrypoint found. Pass one: dartisan serve bin/app.dart');
    exitCode = 2;
    return;
  }
  final passthrough = rest.where((a) => a != entry).toList();
  final serverArgs = passthrough.isEmpty
      ? ['--root=.', '--port=8080']
      : passthrough;
  stdout.writeln('dartisan serve -> dart run $entry ${serverArgs.join(' ')}');
  final proc = await Process.start(
    'dart',
    ['run', entry, ...serverArgs],
    mode: ProcessStartMode.inheritStdio,
  );
  exitCode = await proc.exitCode;
}

String _defaultEntry() {
  final bin = Directory('bin');
  if (!bin.existsSync()) return '';
  if (File('bin/main.dart').existsSync()) return 'bin/main.dart';
  final dart = bin
      .listSync()
      .whereType<File>()
      .firstWhere((f) => f.path.endsWith('.dart'), orElse: () => File(''));
  return dart.path.isEmpty ? '' : dart.path.replaceAll('\\', '/');
}

void _usage() {
  stdout.writeln('''
dartisan — Dartisan project CLI

Usage:
  dartisan new <name>               scaffold a new app
  dartisan make:controller <Name>   create controllers/<name>_controller.dart
  dartisan make:component <Name>    create components/<name>_component.dart (Live)
                                    (add --view for a views/components/<name>.blaze.html)
  dartisan make:model <Name> [f:t]  create models/<name>.dart (record + repository)
  dartisan make:migration <Name>    create migrations/<ts>_<name>.dart (up/down)
  dartisan make:middleware <Name>   create middleware/<name>.dart
  dartisan make:view <name>         create views/<name>.blaze.html
  dartisan migrate [--db=h:p] [--rollback]  run migrations/*.dart (SqlDatabase)
  dartisan routes [entry]           list the app's routes (method + pattern)
  dartisan serve [entry] [args]     run the app (dart run; dev)

Field specs (make:model / make:migration): name:type where type is
  text | integer | real | boolean  (e.g. make:model Post title:text views:integer)
''');
}
