import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'wt/ticket.dart';

/// A reverse-proxy route: requests whose path starts with [pathPrefix] are
/// forwarded to one of [upstreams] (round-robin). Upstreams are base URLs like
/// `http://127.0.0.1:9000`.
class ProxyRoute {
  const ProxyRoute(this.pathPrefix, this.upstreams);
  final String pathPrefix;
  final List<String> upstreams;
}

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
    this.tlsCertPath,
    this.tlsKeyPath,
    this.devMode = false,
    this.tlsEnabled = false,
    this.idleTimeout = const Duration(seconds: 120),
    this.maxRequestBodyBytes = 10 * 1024 * 1024,
    this.proxyRoutes = const [],
    this.wtPath,
    this.wtBridgePath,
    this.spaFallback,
    this.frontController,
    this.wtTicketPath,
    Uint8List? wtTicketKey,
    this.cacheEnabled = false,
    this.cacheMaxBytes = 64 * 1024 * 1024,
    int? workers,
  })  : directoryIndex = directoryIndex ?? const ['index.php', 'index.html'],        wtTicketKey = wtTicketKey ?? WtTicket.generateKey(),        workers = (workers == null || workers < 1)
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

  /// PEM certificate file for TLS (HTTP/3). Required unless [devMode].
  final String? tlsCertPath;

  /// PEM private-key file matching [tlsCertPath].
  final String? tlsKeyPath;

  /// When true, HTTP/3 may use a generated self-signed certificate.
  final bool devMode;

  /// When true, the HTTP/1.1 (TCP) listener terminates TLS (HTTPS), using the
  /// same certificate source as HTTP/3.
  final bool tlsEnabled;

  /// How long an idle keep-alive connection may stay open (slowloris defense).
  final Duration idleTimeout;

  /// Maximum accepted request body size in bytes; larger declared bodies get a
  /// `413 Payload Too Large`.
  final int maxRequestBodyBytes;

  /// Whether the in-memory response micro-cache is enabled (`--cache`).
  final bool cacheEnabled;

  /// LRU byte budget for the response cache (`--cache-max-bytes`).
  final int cacheMaxBytes;

  /// Reverse-proxy routes, checked (longest prefix first) before static/PHP.
  final List<ProxyRoute> proxyRoutes;

  /// When set, HTTP/3 Extended CONNECT requests with `:protocol=webtransport`
  /// on this path open a WebTransport session (datagram echo).
  final String? wtPath;

  /// When set, each complete inbound WebTransport message (stream or datagram)
  /// is bridged to this path as a synthetic `POST` through the PHP pipeline —
  /// e.g. `/livewire/update` for Livewire-over-WebTransport. The response is
  /// written back on the same stream (or returned as a datagram when small
  /// enough). When null, WebTransport messages are echoed instead.
  final String? wtBridgePath;

  /// When set (e.g. `/index.html`), a GET/HEAD request for an **extensionless**
  /// path that resolves to nothing is served this file with `200` instead of a
  /// `404`. This is the single-page-app rewrite (nginx `try_files … /index.html`)
  /// that client-side routing — e.g. a Flutter/Dart web build using
  /// `PathUrlStrategy` — needs so deep links survive a refresh. Missing assets
  /// (anything with a file extension) still `404`.
  final String? spaFallback;

  /// When set (e.g. `/index.php`), a request that resolves to no file is routed
  /// through this PHP front controller with the original `REQUEST_URI`
  /// preserved — the nginx `try_files $uri /index.php?$query_string` pattern
  /// that Laravel and other front-controller frameworks rely on (so routes like
  /// `/livewire/update` reach the app router). Checked before [spaFallback].
  final String? frontController;

  /// When set (e.g. `/wt-ticket`), the server issues an opaque, short-lived
  /// AES-GCM ticket encrypting the request's `Cookie` header. The browser
  /// fetches it over normal HTTPS (where the HttpOnly session cookie is sent)
  /// and carries it on WebTransport messages via `X-WT-Ticket`; the bridge
  /// decrypts it to recover the session — keeping the cookie HttpOnly instead
  /// of forwarding `document.cookie`.
  final String? wtTicketPath;

  /// 256-bit key used to seal/open [wtTicketPath] tickets. Generated per run
  /// unless provided via `--wt-ticket-key` (base64); all workers in a run share
  /// the one key (the config object is copied to each isolate).
  final Uint8List wtTicketKey;

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

    // --laravel=<public-dir> is a convenience bundle: serve a Laravel public/
    // dir through a front controller and turn on the Livewire WebTransport
    // bridge with conventional paths. Explicit flags below still override it.
    final laravel = map['laravel'];
    final root = map['root'] ?? laravel ?? Directory.current.path;
    final port = int.tryParse(map['port'] ?? '') ?? 8080;
    // `--http3` co-locates an h3 listener on the same port, so advertise it
    // automatically unless an explicit --advertise-h3 was given.
    final http3 = args.contains('--http3');
    final altSvcH3Port =
        int.tryParse(map['advertise-h3'] ?? '') ?? (http3 ? port : null);
    // --http3 co-locates h3 on the TCP port, so the h1 side must be HTTPS for
    // browsers to honor Alt-Svc; --https enables HTTPS on h1 without h3.
    final tlsEnabled = http3 || args.contains('--https');

    // Repeatable: --proxy=/prefix=http://host:port[,http://host2:port].
    final proxyRoutes = <ProxyRoute>[];
    for (final arg in args) {
      if (!arg.startsWith('--proxy=')) continue;
      final spec = arg.substring('--proxy='.length);
      final eq = spec.indexOf('=');
      if (eq <= 0) continue;
      final prefix = spec.substring(0, eq);
      final upstreams = spec
          .substring(eq + 1)
          .split(',')
          .map((u) => u.trim())
          .where((u) => u.isNotEmpty)
          .toList();
      if (upstreams.isNotEmpty) proxyRoutes.add(ProxyRoute(prefix, upstreams));
    }
    // Longest prefix first so more specific routes win.
    proxyRoutes.sort((a, b) => b.pathPrefix.length.compareTo(a.pathPrefix.length));

    // --spa is shorthand for --spa-fallback=/index.html.
    final spaFallback = map['spa-fallback'] ??
        (args.contains('--spa') ? '/index.html' : null);

    // Convenience defaults implied by --laravel (explicit flags win).
    final frontController =
        map['front-controller'] ?? (laravel != null ? '/index.php' : null);
    final wtPath = map['wt-path'] ?? (laravel != null ? '/wt' : null);
    final wtBridgePath =
        map['wt-bridge-path'] ?? (laravel != null ? '/livewire/update' : null);
    final wtTicketPath =
        map['wt-ticket-path'] ?? (laravel != null ? '/wt-ticket' : null);

    return ServerConfig(
      address: map['address'] ?? '127.0.0.1',
      port: port,
      documentRoot: Directory(root).absolute.path,
      phpCgiPath: map['php-cgi'] ?? 'php-cgi',
      phpFpm: map['php-fpm'],
      serverName: map['server-name'] ?? 'localhost',
      altSvcH3Port: altSvcH3Port,
      tlsCertPath: map['tls-cert'],
      tlsKeyPath: map['tls-key'],
      devMode: args.contains('--dev'),
      tlsEnabled: tlsEnabled,
      idleTimeout: Duration(
        seconds: int.tryParse(map['idle-timeout'] ?? '') ?? 120,
      ),
      maxRequestBodyBytes:
          int.tryParse(map['max-body'] ?? '') ?? 10 * 1024 * 1024,
      cacheEnabled: args.contains('--cache'),
      cacheMaxBytes:
          int.tryParse(map['cache-max-bytes'] ?? '') ?? 64 * 1024 * 1024,
      proxyRoutes: proxyRoutes,
      wtPath: wtPath,
      wtBridgePath: wtBridgePath,
      spaFallback: spaFallback,
      frontController: frontController,
      wtTicketPath: wtTicketPath,
      wtTicketKey: map['wt-ticket-key'] != null
          ? Uint8List.fromList(base64.decode(map['wt-ticket-key']!))
          : null,
      workers: int.tryParse(map['workers'] ?? ''),
    );
  }
}
