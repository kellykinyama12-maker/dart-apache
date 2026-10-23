// Dartisan events — a tiny, type-keyed event dispatcher (the Laravel event
// bus analog). Register listeners by event type; dispatch delivers an event to
// every listener registered for its concrete runtime type.
import 'dart:async';

/// Handles an event of type `T`.
typedef EventListener<T> = FutureOr<void> Function(T event);

class EventDispatcher {
  final Map<Type, List<Function>> _listeners = {};

  /// Registers [listener] for events of type `T`.
  void listen<T>(EventListener<T> listener) =>
      (_listeners[T] ??= []).add(listener);

  /// True when at least one listener is registered for `T`.
  bool hasListeners<T>() => (_listeners[T]?.isNotEmpty) ?? false;

  /// Delivers [event] to every listener for its runtime type, in registration
  /// order, awaiting async listeners.
  Future<void> dispatch(Object event) async {
    final listeners = _listeners[event.runtimeType];
    if (listeners == null) return;
    for (final listener in List<Function>.of(listeners)) {
      await (listener as dynamic)(event);
    }
  }

  /// Removes all listeners for `T` (or all listeners when `T` is omitted).
  void forget<T>() {
    if (T == Object) {
      _listeners.clear();
    } else {
      _listeners.remove(T);
    }
  }
}
