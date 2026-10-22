/// A server that can run as a supervised worker isolate: it binds a shared
/// listening socket, serves until told to stop, and drains gracefully. Both the
/// HTTP/1.1 (`ApacheServer`) and HTTP/3 (`Http3PhpServer`) servers implement it,
/// so the [ServerSupervisor] can manage either transport uniformly.
abstract interface class WorkerServer {
  /// Binds and starts serving. [workerId] identifies the owning isolate for
  /// logging; when null the server prints its own standalone banner.
  Future<void> start({int? workerId});

  /// Stops accepting new work. When [graceful] is true, in-flight requests are
  /// allowed to finish before the socket closes.
  Future<void> stop({bool graceful});
}
