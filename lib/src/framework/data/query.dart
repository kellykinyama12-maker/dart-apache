// Dartisan data layer — an Eloquent-lite query/record API over a pluggable
// [Database]. Ships a pure-Dart [InMemoryDatabase] (no FFI, no deps); a real
// driver (e.g. pure-Dart Postgres) can implement [Database] with the same API.
import 'dart:async';

/// A database backend. Drivers implement the four operations; apps use the
/// chainable [QueryBuilder] returned by [table].
abstract class Database {
  /// Starts a query against [name].
  QueryBuilder table(String name) => QueryBuilder(this, name);

  Future<List<Map<String, Object?>>> runSelect(QueryBuilder query);
  Future<Map<String, Object?>> runInsert(
      String table, Map<String, Object?> data);
  Future<int> runUpdate(QueryBuilder query, Map<String, Object?> data);
  Future<int> runDelete(QueryBuilder query);

  /// Counts rows matching the query's filter, ignoring limit/offset.
  Future<int> runCount(QueryBuilder query);
}

/// A page of results plus paging metadata (the Laravel `LengthAwarePaginator`
/// analog). Use [toMap] to hand it to a Blaze view.
class Paginator<T> {
  Paginator(this.items,
      {required this.total, required this.page, required this.perPage});

  final List<T> items;
  final int total;
  final int page;
  final int perPage;

  int get lastPage => perPage <= 0 ? 1 : ((total + perPage - 1) ~/ perPage);
  bool get hasPrev => page > 1;
  bool get hasNext => page < lastPage;
  int? get prevPage => hasPrev ? page - 1 : null;
  int? get nextPage => hasNext ? page + 1 : null;
  int get from => total == 0 ? 0 : (page - 1) * perPage + 1;
  int get to => total == 0 ? 0 : from + items.length - 1;

  /// A window of page numbers around the current page (for rendering a pager).
  List<int> pages({int onEachSide = 2}) {
    final start = (page - onEachSide).clamp(1, lastPage);
    final end = (page + onEachSide).clamp(1, lastPage);
    return [for (var p = start; p <= end; p++) p];
  }

  Map<String, Object?> toMap() => {
        'items': items,
        'total': total,
        'page': page,
        'perPage': perPage,
        'lastPage': lastPage,
        'hasPrev': hasPrev,
        'hasNext': hasNext,
        'prevPage': prevPage,
        'nextPage': nextPage,
        'from': from,
        'to': to,
        'pages': pages(),
      };
}

/// One `WHERE` condition.
class WhereClause {
  const WhereClause(this.field, this.op, this.value);
  final String field;
  final String op;
  final Object? value;

  bool matches(Map<String, Object?> row) {
    final actual = row[field];
    switch (op) {
      case '=':
        return actual == value;
      case '!=':
        return actual != value;
      case '<':
        return _cmp(actual, value) < 0;
      case '>':
        return _cmp(actual, value) > 0;
      case '<=':
        return _cmp(actual, value) <= 0;
      case '>=':
        return _cmp(actual, value) >= 0;
      case 'in':
        return value is Iterable && (value as Iterable).contains(actual);
      case 'like':
        final needle = '$value'.toLowerCase().replaceAll('%', '');
        return '$actual'.toLowerCase().contains(needle);
      default:
        return false;
    }
  }
}

int _cmp(Object? a, Object? b) {
  if (a is num && b is num) return a.compareTo(b);
  return '$a'.compareTo('$b');
}

/// A chainable query over a [Database] table. Terminal methods ([get], [first],
/// [count], [insert], [update], [delete]) execute against the driver.
class QueryBuilder {
  QueryBuilder(this._db, this.table);

  static const Object _unset = Object();

  final Database _db;
  final String table;
  final List<WhereClause> wheres = [];
  String? orderByField;
  bool descending = false;
  int? limitCount;
  int? offsetCount;

  /// `where('age', 18)` (equality) or `where('age', '>=', 18)` (operator).
  QueryBuilder where(String field, Object? opOrValue, [Object? value = _unset]) {
    if (identical(value, _unset)) {
      wheres.add(WhereClause(field, '=', opOrValue));
    } else {
      wheres.add(WhereClause(field, opOrValue as String, value));
    }
    return this;
  }

  QueryBuilder whereIn(String field, Iterable<Object?> values) {
    wheres.add(WhereClause(field, 'in', values));
    return this;
  }

  /// `WHERE field IS NULL`.
  QueryBuilder whereNull(String field) => where(field, '=', null);

  /// `WHERE field IS NOT NULL`.
  QueryBuilder whereNotNull(String field) => where(field, '!=', null);

  QueryBuilder orderBy(String field, {bool descending = false}) {
    orderByField = field;
    this.descending = descending;
    return this;
  }

  /// `orderBy(field, descending: true)`.
  QueryBuilder orderByDesc(String field) => orderBy(field, descending: true);

  QueryBuilder limit(int n) {
    limitCount = n;
    return this;
  }

  QueryBuilder offset(int n) {
    offsetCount = n;
    return this;
  }

  bool matches(Map<String, Object?> row) => wheres.every((w) => w.matches(row));

  Future<List<Map<String, Object?>>> get() => _db.runSelect(this);

  Future<Map<String, Object?>?> first() async {
    final rows = await (limit(1).get());
    return rows.isEmpty ? null : rows.first;
  }

  /// The row with the given `id` (shorthand for `where('id', id).first()`).
  Future<Map<String, Object?>?> find(Object? id) => where('id', id).first();

  /// A single column [field] from the first matching row, or null.
  Future<Object?> value(String field) async => (await first())?[field];

  /// Whether any row matches the current filter.
  Future<bool> exists() async => (await count()) > 0;

  /// A list of one column [field] across all matching rows.
  Future<List<Object?>> pluck(String field) async =>
      (await get()).map((r) => r[field]).toList();

  /// Counts rows matching the filter (ignoring limit/offset).
  Future<int> count() => _db.runCount(this);

  /// Returns page [page] (1-based) of [perPage] rows plus paging metadata.
  Future<Paginator<Map<String, Object?>>> paginate(
      {int page = 1, int perPage = 15}) async {
    final total = await _db.runCount(this);
    final items = await (limit(perPage).offset((page - 1) * perPage).get());
    return Paginator(items, total: total, page: page, perPage: perPage);
  }

  /// Inserts [data] and returns the stored row (with its `id`).
  Future<Map<String, Object?>> insert(Map<String, Object?> data) =>
      _db.runInsert(table, data);

  /// Updates rows matching the current filter; returns the affected count.
  Future<int> update(Map<String, Object?> data) => _db.runUpdate(this, data);

  /// Deletes rows matching the current filter; returns the affected count.
  Future<int> delete() => _db.runDelete(this);
}

/// A pure-Dart, in-memory [Database] — zero dependencies, ideal for tests,
/// prototypes, and small apps. Auto-increments an `id` per table.
class InMemoryDatabase implements Database {
  final Map<String, List<Map<String, Object?>>> _tables = {};
  final Map<String, int> _seq = {};

  @override
  QueryBuilder table(String name) => QueryBuilder(this, name);

  List<Map<String, Object?>> _rows(String t) =>
      _tables.putIfAbsent(t, () => []);

  @override
  Future<List<Map<String, Object?>>> runSelect(QueryBuilder q) async {
    var rows = _rows(q.table).where(q.matches).toList();
    final field = q.orderByField;
    if (field != null) {
      rows.sort((a, b) => _cmp(a[field], b[field]) * (q.descending ? -1 : 1));
    }
    if (q.offsetCount != null) rows = rows.skip(q.offsetCount!).toList();
    if (q.limitCount != null) rows = rows.take(q.limitCount!).toList();
    // Return copies so callers can't mutate the store directly.
    return rows.map((r) => Map<String, Object?>.of(r)).toList();
  }

  @override
  Future<Map<String, Object?>> runInsert(
      String table, Map<String, Object?> data) async {
    final id = _seq[table] = (_seq[table] ?? 0) + 1;
    final row = <String, Object?>{'id': id, ...data};
    _rows(table).add(row);
    return Map<String, Object?>.of(row);
  }

  @override
  Future<int> runUpdate(QueryBuilder q, Map<String, Object?> data) async {
    var n = 0;
    for (final r in _rows(q.table)) {
      if (q.matches(r)) {
        r.addAll(data);
        n++;
      }
    }
    return n;
  }

  @override
  Future<int> runDelete(QueryBuilder q) async {
    final rows = _rows(q.table);
    final before = rows.length;
    rows.removeWhere(q.matches);
    return before - rows.length;
  }

  @override
  Future<int> runCount(QueryBuilder q) async =>
      _rows(q.table).where(q.matches).length;
}
