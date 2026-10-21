import 'dart:io';

/// Server configuration, mirroring the handful of Apache directives that matter
/// for serving files and running PHP: `Listen`, `DocumentRoot`,
/// `DirectoryIndex`, and the CGI handler binary.
class ServerConfig {
  ServerConfig({
    this.address = '127.0.0.1',
    this.port = 8080,
    required this.documentRoot,
    this.phpCgiPath = 'php-cgi',
    List<String>? directoryIndex,
    this.serverName = 'localhost',
    this.serverSoftware = 'dart-apache/1.0.0',
    int? workers,
  })  : directoryIndex = directoryIndex ?? const ['index.php', 'index.html'],
        workers = (workers == null || workers < 1)
            ? Platform.numberOfProcessors
            : workers;

  /// Interface to bind to.
  final String address;

  /// TCP port to listen on (Apache `Listen`).
  final int port;

  /// Absolute path to the folder served to clients (Apache `DocumentRoot`).
  final String documentRoot;

  /// Path to the `php-cgi` executable used as the CGI handler.
  final String phpCgiPath;

  /// Files tried, in order, when a directory is requested (`DirectoryIndex`).
  final List<String> directoryIndex;

  /// Reported as `SERVER_NAME` to CGI scripts.
  final String serverName;

  /// Reported as `SERVER_SOFTWARE` and the `Server:` response header.
  final String serverSoftware;

  /// Number of worker isolates to run (one acceptor per core by default).
  /// Each worker binds the same port with a shared socket; the kernel/runtime
  /// load-balances connections across them.
  final int workers;

  /// Parses `key=value` style CLI arguments into a [ServerConfig].
  ///
  /// Supported flags: `--address`, `--port`, `--root`, `--php-cgi`,
  /// `--server-name`, `--workers`.
  factory ServerConfig.fromArgs(List<String> args) {
    final map = <String, String>{};
    for (final arg in args) {
      if (arg.startsWith('--') && arg.contains('=')) {
        final i = arg.indexOf('=');
        map[arg.substring(2, i)] = arg.substring(i + 1);
      }
    }

    final root = map['root'] ?? Directory.current.path;

    return ServerConfig(
      address: map['address'] ?? '127.0.0.1',
      port: int.tryParse(map['port'] ?? '') ?? 8080,
      documentRoot: Directory(root).absolute.path,
      phpCgiPath: map['php-cgi'] ?? 'php-cgi',
      serverName: map['server-name'] ?? 'localhost',
      workers: int.tryParse(map['workers'] ?? ''),
    );
  }
}
