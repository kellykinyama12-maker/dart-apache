// A networked SQL [Database] driver — pure `dart:io`, no dependencies. Speaks
// the newline-delimited JSON protocol of dart-db-server
// (https://github.com/KellyKinyama/dart-db-server):
//   request:  {"id": 1, "sql": "SELECT * FROM users"}
//   response: {"id": 1, "ok": true, "columns": [...], "rows": [[...]], "affected": n}
// Unlike the in-memory driver this gives shared, persistent state across the
// worker-per-isolate model — each worker opens its own connection to the server.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'query.dart';

/// Thrown when the server reports a query error.
class SqlException implements Exception {
  SqlException(this.message);
  final String message;
  @override
  String toString() => 'SqlException: $message';
}

/// The raw result of a statement: column names, rows, and affected count.
class SqlResult {
  SqlResult(this.columns, this.rows, this.affected);
  final List<String> columns;
  final List<List<Object?>> rows;
  final int affected;

  /// Rows as `column -> value` maps.
  List<Map<String, Object?>> asMaps() => [
        for (final row in rows)
          {for (var i = 0; i < columns.length; i++) columns[i]: row[i]}
      ];
}

/// A [Database] backed by a dart-db-server over TCP.
class SqlDatabase implements Database {
  SqlDatabase({
    required this.host,
    required this.port,
    this.timeout = const Duration(seconds: 10),
  });

  final String host;
  final int port;
  final Duration timeout;

  Socket? _socket;
  Future<void>? _connecting;
  int _nextId = 1;
  final Map<int, Completer<Map<String, Object?>>> _pending = {};
  final List<int> _buffer = [];

  @override
  QueryBuilder table(String name) => QueryBuilder(this, name);

  /// Runs arbitrary [sql] (e.g. DDL/migrations) and returns the raw result.
  Future<SqlResult> execute(String sql) async {
    final res = await _send(sql);
    return SqlResult(
      ((res['columns'] as List?) ?? const []).cast<String>(),
      ((res['rows'] as List?) ?? const [])
          .map((r) => (r as List).cast<Object?>())
          .toList(),
      (res['affected'] as num?)?.toInt() ?? 0,
    );
  }

  /// Closes the connection.
  Future<void> close() async {
    _socket?.destroy();
    _socket = null;
    _connecting = null;
  }

  // ---- Database contract ----

  @override
  Future<List<Map<String, Object?>>> runSelect(QueryBuilder q) async {
    final sql = StringBuffer('SELECT * FROM ${q.table}')..write(_where(q.wheres));
    final field = q.orderByField;
    if (field != null) {
      sql.write(' ORDER BY $field ${q.descending ? 'DESC' : 'ASC'}');
    }
    if (q.limitCount != null) sql.write(' LIMIT ${q.limitCount}');
    if (q.offsetCount != null) sql.write(' OFFSET ${q.offsetCount}');
    return (await execute(sql.toString())).asMaps();
  }

  @override
  Future<Map<String, Object?>> runInsert(
      String table, Map<String, Object?> data) async {
    final cols = data.keys.toList();
    final values = cols.map((c) => _literal(data[c])).join(', ');
    final sql = 'INSERT INTO $table (${cols.join(', ')}) '
        'VALUES ($values) RETURNING *';
    final rows = (await execute(sql)).asMaps();
    return rows.isNotEmpty ? rows.first : Map<String, Object?>.of(data);
  }

  @override
  Future<int> runUpdate(QueryBuilder q, Map<String, Object?> data) async {
    final sets =
        data.entries.map((e) => '${e.key} = ${_literal(e.value)}').join(', ');
    final sql = 'UPDATE ${q.table} SET $sets${_where(q.wheres)}';
    return (await execute(sql)).affected;
  }

  @override
  Future<int> runDelete(QueryBuilder q) async =>
      (await execute('DELETE FROM ${q.table}${_where(q.wheres)}')).affected;

  @override
  Future<int> runCount(QueryBuilder q) async {
    final res =
        await execute('SELECT COUNT(*) AS n FROM ${q.table}${_where(q.wheres)}');
    return res.rows.isEmpty ? 0 : (res.rows.first.first as num).toInt();
  }

  // ---- SQL building ----

  static String _where(List<WhereClause> wheres) {
    if (wheres.isEmpty) return '';
    return ' WHERE ${wheres.map(_condition).join(' AND ')}';
  }

  static String _condition(WhereClause w) {
    if (w.op == 'in') {
      final list = (w.value as Iterable).map(_literal).join(', ');
      return '${w.field} IN ($list)';
    }
    if (w.op == 'like') {
      final needle = '${w.value}'.replaceAll("'", "''");
      return "${w.field} LIKE '%$needle%'";
    }
    if (w.value == null) {
      if (w.op == '=') return '${w.field} IS NULL';
      if (w.op == '!=') return '${w.field} IS NOT NULL';
    }
    return '${w.field} ${w.op} ${_literal(w.value)}';
  }

  static String _literal(Object? value) {
    if (value == null) return 'NULL';
    if (value is num) return '$value';
    if (value is bool) return value ? 'TRUE' : 'FALSE';
    return "'${value.toString().replaceAll("'", "''")}'";
  }

  // ---- transport ----

  Future<Map<String, Object?>> _send(String sql) async {
    await _ensureConnected();
    final id = _nextId++;
    final completer = Completer<Map<String, Object?>>();
    _pending[id] = completer;
    _socket!.add(utf8.encode('${jsonEncode({'id': id, 'sql': sql})}\n'));
    return completer.future;
  }

  Future<void> _ensureConnected() {
    if (_socket != null) return Future<void>.value();
    return _connecting ??= _connect();
  }

  Future<void> _connect() async {
    final socket = await Socket.connect(host, port, timeout: timeout);
    _socket = socket;
    socket.listen(_onData, onError: _failAll, onDone: () => _failAll(
        const SocketException('connection closed'), StackTrace.current));
  }

  void _onData(List<int> data) {
    for (final b in data) {
      if (b == 0x0a) {
        final line = utf8.decode(_buffer);
        _buffer.clear();
        _dispatch(line);
      } else {
        _buffer.add(b);
      }
    }
  }

  void _dispatch(String line) {
    if (line.trim().isEmpty) return;
    final obj = (jsonDecode(line) as Map).cast<String, Object?>();
    final id = (obj['id'] as num?)?.toInt();
    final completer = id == null ? null : _pending.remove(id);
    if (completer == null) return;
    if (obj['ok'] == false) {
      completer.completeError(SqlException('${obj['error'] ?? 'query failed'}'));
    } else {
      completer.complete(obj);
    }
  }

  void _failAll(Object error, StackTrace stackTrace) {
    _socket = null;
    _connecting = null;
    final pending = _pending.values.toList();
    _pending.clear();
    for (final c in pending) {
      if (!c.isCompleted) c.completeError(error, stackTrace);
    }
  }
}
