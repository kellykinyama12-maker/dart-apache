// Dartisan collection helpers — small, lean extensions on `Iterable` that fill
// the gaps Dart's core doesn't cover (grouping/keying/sorting/plucking), handy
// for working with rows returned from the query builder.

extension DartisanIterable<E> on Iterable<E> {
  /// A new list sorted by the [key] extracted from each element.
  List<E> sortedBy<K extends Comparable<Object>>(K Function(E element) key) {
    final copy = toList();
    copy.sort((a, b) => key(a).compareTo(key(b)));
    return copy;
  }

  /// A new list sorted in descending order by [key].
  List<E> sortedByDesc<K extends Comparable<Object>>(K Function(E element) key) {
    final copy = toList();
    copy.sort((a, b) => key(b).compareTo(key(a)));
    return copy;
  }

  /// Groups elements into a map of `key -> elements` preserving iteration order.
  Map<K, List<E>> groupBy<K>(K Function(E element) key) {
    final out = <K, List<E>>{};
    for (final element in this) {
      (out[key(element)] ??= <E>[]).add(element);
    }
    return out;
  }

  /// Indexes elements by [key] (later elements win on collision).
  Map<K, E> keyBy<K>(K Function(E element) key) {
    final out = <K, E>{};
    for (final element in this) {
      out[key(element)] = element;
    }
    return out;
  }
}

extension DartisanRows on Iterable<Map<String, Object?>> {
  /// Extracts a single column [key] from each row.
  List<Object?> pluck(String key) => map((row) => row[key]).toList();
}
