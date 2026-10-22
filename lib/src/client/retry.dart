/// Controls automatic retries. An attempt is retried when it throws a network
/// error (and [retryOnError]) or returns a status in [retryStatuses], up to
/// [maxRetries] extra attempts, waiting [backoff] between tries.
class RetryPolicy {
  const RetryPolicy({
    this.maxRetries = 2,
    this.retryStatuses = const {408, 429, 500, 502, 503, 504},
    this.retryOnError = true,
    this.backoff = _defaultBackoff,
  });

  /// No retries.
  static const RetryPolicy none = RetryPolicy(maxRetries: 0, retryOnError: false);

  final int maxRetries;
  final Set<int> retryStatuses;
  final bool retryOnError;

  /// Delay before retry [attempt] (1-based). Default: 200ms, 400ms, 800ms…
  final Duration Function(int attempt) backoff;

  bool shouldRetryStatus(int statusCode) => retryStatuses.contains(statusCode);

  static Duration _defaultBackoff(int attempt) =>
      Duration(milliseconds: 200 * (1 << (attempt - 1)));
}
