import 'dart:async';

/// Thrown when a request is aborted via a [CancelToken].
class RequestCancelledException implements Exception {
  RequestCancelledException([this.reason]);
  final String? reason;
  @override
  String toString() =>
      'RequestCancelledException${reason == null ? '' : ': $reason'}';
}

/// A cooperative cancellation handle. Pass the same token to one or more
/// requests and call [cancel] to abort them; in-flight requests complete with
/// a [RequestCancelledException].
class CancelToken {
  final Completer<void> _completer = Completer<void>();
  String? _reason;

  /// Whether [cancel] has been called.
  bool get isCancelled => _completer.isCompleted;

  /// The reason passed to [cancel], if any.
  String? get reason => _reason;

  /// Completes when the token is cancelled. Used internally to race requests.
  Future<void> get whenCancelled => _completer.future;

  /// Cancels the token, aborting any request it was passed to.
  void cancel([String? reason]) {
    if (_completer.isCompleted) return;
    _reason = reason;
    _completer.complete();
  }

  /// Throws if already cancelled (checked before each attempt).
  void throwIfCancelled() {
    if (isCancelled) throw RequestCancelledException(_reason);
  }
}
