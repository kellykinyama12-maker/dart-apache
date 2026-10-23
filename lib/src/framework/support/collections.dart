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

  /// Sums the numeric [value] extracted from each element.
  num sumBy(num Function(E element) value) {
    num total = 0;
    for (final element in this) {
      total += value(element);
    }
    return total;
  }

  /// The average of the numeric [value] over all elements (0 when empty).
  num avgBy(num Function(E element) value) {
    var count = 0;
    num total = 0;
    for (final element in this) {
      total += value(element);
      count++;
    }
    return count == 0 ? 0 : total / count;
  }

  /// The element with the greatest [key], or null when empty.
  E? maxBy<K extends Comparable<Object>>(K Function(E element) key) {
    E? best;
    K? bestKey;
    for (final element in this) {
      final k = key(element);
      if (bestKey == null || k.compareTo(bestKey) > 0) {
        best = element;
        bestKey = k;
      }
    }
    return best;
  }

  /// The element with the smallest [key], or null when empty.
  E? minBy<K extends Comparable<Object>>(K Function(E element) key) {
    E? best;
    K? bestKey;
    for (final element in this) {
      final k = key(element);
      if (bestKey == null || k.compareTo(bestKey) < 0) {
        best = element;
        bestKey = k;
      }
    }
    return best;
  }
}

extension DartisanRows on Iterable<Map<String, Object?>> {
  /// Extracts a single column [key] from each row.
  List<Object?> pluck(String key) => map((row) => row[key]).toList();
}
