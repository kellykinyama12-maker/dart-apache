import 'dart:io';

/// Cross-compiles all dart-apache executables to native Linux binaries.
///
///   dart run tool/build_linux.dart            # linux-x64 (default)
///   dart run tool/build_linux.dart arm64      # linux-arm64
///
/// Output goes to `build/`. Requires a Dart SDK with cross-compilation
/// (`dart compile exe --target-os`). Runs from any host OS.
Future<void> main(List<String> args) async {
  final arch = args.isNotEmpty ? args.first : 'x64';
  final targets = {
    'bin/dart_apache.dart': 'dart_apache',
    'bin/dart_apache_h3.dart': 'dart_apache_h3',
    'bin/dart_apache_client.dart': 'dart_apache_client',
  };

  Directory('build').createSync(recursive: true);

  for (final entry in targets.entries) {
    final output = 'build/${entry.value}-linux-$arch';
    stdout.writeln('Compiling ${entry.key} -> $output');
    final result = await Process.run('dart', [
      'compile',
      'exe',
      entry.key,
      '-o',
      output,
      '--target-os',
      'linux',
      '--target-arch',
      arch,
    ]);
    if (result.exitCode != 0) {
      stderr.writeln(result.stdout);
      stderr.writeln(result.stderr);
      exitCode = result.exitCode;
      return;
    }
  }
  stdout.writeln('Done. Linux ($arch) binaries are in build/.');
}
