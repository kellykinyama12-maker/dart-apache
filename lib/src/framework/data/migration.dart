// Dartisan migrations — a minimal migrate/rollback runner over [SqlDatabase].
// Each migration declares `up`/`down`; the [Migrator] tracks what's applied in
// a `schema_migrations` table and runs pending migrations (or rolls back the
// last batch) in deterministic order.
import 'dart:math';

import 'sql_database.dart';

/// A single schema change. [name] must be unique and sort in apply order
/// (the generator prefixes a timestamp, e.g. `20260101120000_create_posts`).
abstract class Migration {
  String get name;
  Future<void> up(SqlDatabase db);
  Future<void> down(SqlDatabase db);
}

/// Applies and rolls back [migrations] against a [SqlDatabase], recording
/// progress in a `schema_migrations` table so each runs at most once.
class Migrator {
  Migrator(this.db, this.migrations);

  final SqlDatabase db;
  final List<Migration> migrations;

  Future<void> _ensureTable() => db.execute(
      'CREATE TABLE IF NOT EXISTS schema_migrations '
      '(name TEXT PRIMARY KEY, batch INTEGER)');

  Future<List<Map<String, Object?>>> _appliedRows() =>
      db.table('schema_migrations').get();

  /// Runs every migration not yet applied, in name order, as one new batch.
  /// Returns the names that ran.
  Future<List<String>> migrate() async {
    await _ensureTable();
    final rows = await _appliedRows();
    final applied = rows.map((r) => r['name']).toSet();
    final batch = rows.isEmpty
        ? 1
        : rows.map((r) => (r['batch'] as num).toInt()).reduce(max) + 1;

    final pending = [...migrations]..sort((a, b) => a.name.compareTo(b.name));
    final ran = <String>[];
    for (final m in pending) {
      if (applied.contains(m.name)) continue;
      await m.up(db);
      await db
          .table('schema_migrations')
          .insert({'name': m.name, 'batch': batch});
      ran.add(m.name);
    }
    return ran;
  }

  /// Rolls back every migration in the most recent batch, in reverse name
  /// order. Returns the names that were rolled back.
  Future<List<String>> rollback() async {
    await _ensureTable();
    final rows = await _appliedRows();
    if (rows.isEmpty) return const [];
    final lastBatch =
        rows.map((r) => (r['batch'] as num).toInt()).reduce(max);
    final inBatch = rows
        .where((r) => (r['batch'] as num).toInt() == lastBatch)
        .map((r) => r['name'] as String)
        .toSet();

    final ordered = [...migrations]..sort((a, b) => b.name.compareTo(a.name));
    final rolled = <String>[];
    for (final m in ordered) {
      if (!inBatch.contains(m.name)) continue;
      await m.down(db);
      await db.table('schema_migrations').where('name', m.name).delete();
      rolled.add(m.name);
    }
    return rolled;
  }
}
