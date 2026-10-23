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
      _make('components', rest, componentSource, suffix: '_component');
    case 'make:model':
      _makeModel(rest);
    case 'make:migration':
      _makeMigration(rest);
    case 'make:middleware':
      _make('middleware', rest, middlewareSource, suffix: '');
    case 'make:view':
      _makeView(rest);
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
  _write('migrations/${_timestamp()}_${snakeCase(name)}.dart',
      migrationSource(name, table: table, fields: fields));
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
  dartisan make:model <Name> [f:t]  create models/<name>.dart (record + repository)
  dartisan make:migration <Name>    create migrations/<ts>_<name>.dart (up/down)
  dartisan make:middleware <Name>   create middleware/<name>.dart
  dartisan make:view <name>         create views/<name>.blaze.html
  dartisan serve [entry] [args]     run the app (dart run; dev)

Field specs (make:model / make:migration): name:type where type is
  text | integer | real | boolean  (e.g. make:model Post title:text views:integer)
''');
}
