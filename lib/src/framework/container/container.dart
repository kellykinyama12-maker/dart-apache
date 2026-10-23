// Dartisan service container — a small, type-keyed dependency injection
// container (the Laravel `Container` analog). Bind factories or singletons by
// type and resolve them with [make]. One container lives per worker isolate.

/// Builds an instance of `T`, given the [Container] (so dependencies can be
/// resolved recursively).
typedef ServiceFactory<T> = T Function(Container container);

class _Binding {
  _Binding(this.factory, this.shared);
  final ServiceFactory<Object?> factory;
  final bool shared;
}

/// A type-keyed IoC container. Register with [bind] (a fresh instance per
/// [make]), [singleton] (built once, then cached), or [instance] (a value you
/// already have); resolve with [make].
class Container {
  final Map<Type, _Binding> _bindings = {};
  final Map<Type, Object?> _instances = {};

  /// Registers a transient factory for `T`.
  void bind<T>(ServiceFactory<T> factory) =>
      _bindings[T] = _Binding(factory, false);

  /// Registers a shared factory for `T` (built lazily, once).
  void singleton<T>(ServiceFactory<T> factory) =>
      _bindings[T] = _Binding(factory, true);

  /// Registers an existing [value] as the singleton for `T`.
  void instance<T>(T value) => _instances[T] = value;

  /// True when `T` can be resolved.
  bool has<T>() => _instances.containsKey(T) || _bindings.containsKey(T);

  /// Resolves `T`, throwing [StateError] if nothing is bound.
  T make<T>() {
    if (_instances.containsKey(T)) return _instances[T] as T;
    final binding = _bindings[T];
    if (binding == null) {
      throw StateError('Container has no binding for $T');
    }
    final built = binding.factory(this) as T;
    if (binding.shared) _instances[T] = built;
    return built;
  }
}
