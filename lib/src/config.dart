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
    this.phpFpm,
    List<String>? directoryIndex,
    this.serverName = 'localhost',
    this.serverSoftware = 'dart-apache/1.0.0',
    this.altSvcH3Port,
    this.altSvcMaxAge = 86400,
    this.idleTimeout = const Duration(seconds: 120),
    this.maxRequestBodyBytes = 10 * 1024 * 1024,
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

  /// Optional PHP-FPM FastCGI target (`host:port` or `unix:/path`). When set,
  /// PHP runs via FastCGI instead of spawning `php-cgi` per request.
  final String? phpFpm;

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

  /// When set, HTTP responses advertise HTTP/3 availability on this UDP port
  /// via the `Alt-Svc` header (RFC 7838/9114), so capable clients upgrade to
  /// QUIC on a later request.
  final int? altSvcH3Port;

  /// `ma` (max-age) seconds for the advertised `Alt-Svc` entry.
  final int altSvcMaxAge;

  /// How long an idle keep-alive connection may stay open (slowloris defense).
  final Duration idleTimeout;

  /// Maximum accepted request body size in bytes; larger declared bodies get a
  /// `413 Payload Too Large`.
  final int maxRequestBodyBytes;

  /// The `Alt-Svc` header value advertising HTTP/3, or null if disabled.
  String? get altSvcHeader => altSvcH3Port == null
      ? null
      : 'h3=":$altSvcH3Port"; ma=$altSvcMaxAge';

  /// Parses `key=value` style CLI arguments into a [ServerConfig].
  ///
  /// Supported flags: `--address`, `--port`, `--root`, `--php-cgi`,
  /// `--server-name`, `--workers`, `--advertise-h3`.
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
      phpFpm: map['php-fpm'],
      serverName: map['server-name'] ?? 'localhost',
      altSvcH3Port: int.tryParse(map['advertise-h3'] ?? ''),
      idleTimeout: Duration(
        seconds: int.tryParse(map['idle-timeout'] ?? '') ?? 120,
      ),
      maxRequestBodyBytes:
          int.tryParse(map['max-body'] ?? '') ?? 10 * 1024 * 1024,
      workers: int.tryParse(map['workers'] ?? ''),
    );
  }
}
