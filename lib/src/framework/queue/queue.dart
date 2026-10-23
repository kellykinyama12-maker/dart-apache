// Dartisan queue — an in-memory, in-process async job queue (the Laravel queue
// analog, 'sync'/'array'-style). Push [Job]s to run off the request path; the
// queue drains them FIFO, supports a delay, and retries up to [maxAttempts].
import 'dart:async';
import 'dart:collection';

/// A unit of deferred work.
abstract class Job {
  FutureOr<void> handle();
}

/// Called when a job has exhausted its attempts.
typedef JobErrorHandler = void Function(
    Job job, Object error, StackTrace stackTrace);

class Queue {
  Queue({this.maxAttempts = 1, this.onFailed});

  /// How many times a failing job is tried before [onFailed] fires.
  final int maxAttempts;
  final JobErrorHandler? onFailed;

  final ListQueue<Job> _ready = ListQueue<Job>();
  int _inFlight = 0;
  bool _draining = false;

  /// Jobs waiting to run (not counting delayed-but-not-yet-ready ones).
  int get pending => _ready.length;

  /// Enqueues [job], optionally after [delay].
  void push(Job job, {Duration delay = Duration.zero}) {
    if (delay > Duration.zero) {
      Timer(delay, () {
        _ready.add(job);
        _schedule();
      });
    } else {
      _ready.add(job);
      _schedule();
    }
  }

  // Drain on a later microtask so push returns immediately (off the caller's
  // synchronous path); the _draining guard collapses repeated schedules.
  void _schedule() => scheduleMicrotask(() => unawaited(_drain()));

  Future<void> _drain() async {
    if (_draining) return;
    _draining = true;
    while (_ready.isNotEmpty) {
      final job = _ready.removeFirst();
      _inFlight++;
      try {
        await _run(job);
      } finally {
        _inFlight--;
      }
    }
    _draining = false;
  }

  Future<void> _run(Job job) async {
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        await job.handle();
        return;
      } catch (error, stackTrace) {
        if (attempt >= maxAttempts) {
          onFailed?.call(job, error, stackTrace);
          return;
        }
      }
    }
  }

  /// Completes once the queue is idle (no ready or in-flight jobs). Delayed jobs
  /// whose timer has not fired yet are not awaited.
  Future<void> settle() async {
    while (_draining || _ready.isNotEmpty || _inFlight > 0) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
  }
}

/// A [Job] that runs a closure — handy for one-off work without a class.
class CallbackJob implements Job {
  CallbackJob(this._work);
  final FutureOr<void> Function() _work;
  @override
  FutureOr<void> handle() => _work();
}
