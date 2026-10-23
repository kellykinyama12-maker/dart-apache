import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

/// One cached static file: identity bytes, an optional precomputed gzip
/// representation, and the validators needed to answer conditional / range
/// requests from memory.
class StaticEntry {
  StaticEntry({
    required this.bytes,
    required this.gzip,
    required this.etag,
    required this.contentType,
    required this.modified,
    required this.validUntil,
  });

  final Uint8List bytes;
  final Uint8List? gzip;
  final String etag;
  final String contentType;
  final DateTime modified;
  DateTime validUntil;

  int get length => bytes.length;
  int get footprint => bytes.length + (gzip?.length ?? 0);
}

/// An in-memory hot-file cache for static serving — the dart-apache analog of
/// nginx's `open_file_cache`. It holds a file's bytes, ETag and a precomputed
/// gzip variant, and re-`stat`s the file **at most once per [ttl]** so repeated
/// requests avoid the per-request `stat()` + `open()` + gzip work. Files larger
/// than [maxFileBytes] are not cached (the caller streams them from disk). A
/// byte [budget] bounds memory with simple LRU eviction.
class StaticFileCache {
  StaticFileCache({
    required this.maxFileBytes,
    this.ttl = const Duration(seconds: 1),
    this.budget = 64 * 1024 * 1024,
  });

  final int maxFileBytes;
  final Duration ttl;
  final int budget;

  final LinkedHashMap<String, StaticEntry> _entries =
      LinkedHashMap<String, StaticEntry>();
  int _bytes = 0;

  /// Returns a cached entry for [path], loading/refreshing it as needed, or
  /// null when the file is missing or too big to cache (caller falls back to
  /// streaming from disk). Within [ttl] of the last check, returns the cached
  /// entry with **no** filesystem access.
  Future<StaticEntry?> load(
    String path, {
    required String contentType,
    required bool compressible,
    required int gzipMin,
    required int gzipMax,
  }) async {
    final now = DateTime.now();
    final cached = _entries[path];
    if (cached != null && now.isBefore(cached.validUntil)) {
      _touch(path, cached);
      return cached;
    }

    final FileStat st;
    try {
      st = await FileStat.stat(path);
    } catch (_) {
      _evict(path);
      return null;
    }
    if (st.type != FileSystemEntityType.file) {
      _evict(path);
      return null;
    }
    if (st.size > maxFileBytes) {
      _evict(path); // too big to cache; caller streams it
      return null;
    }

    // Unchanged since last load -> just extend the validity window.
    if (cached != null &&
        cached.modified == st.modified &&
        cached.length == st.size) {
      cached.validUntil = now.add(ttl);
      _touch(path, cached);
      return cached;
    }

    final bytes = await File(path).readAsBytes();
    final etag = '"${(st.modified.millisecondsSinceEpoch ~/ 1000)
        .toRadixString(16)}-${st.size.toRadixString(16)}"';
    Uint8List? gz;
    if (compressible && bytes.length >= gzipMin && bytes.length <= gzipMax) {
      gz = Uint8List.fromList(gzip.encode(bytes));
    }
    final entry = StaticEntry(
      bytes: bytes,
      gzip: gz,
      etag: etag,
      contentType: contentType,
      modified: st.modified,
      validUntil: now.add(ttl),
    );
    _put(path, entry);
    return entry;
  }

  void _touch(String path, StaticEntry e) {
    _entries.remove(path);
    _entries[path] = e; // move to MRU position
  }

  void _put(String path, StaticEntry e) {
    _evict(path);
    _entries[path] = e;
    _bytes += e.footprint;
    while (_bytes > budget && _entries.isNotEmpty) {
      _evict(_entries.keys.first); // drop LRU
    }
  }

  void _evict(String path) {
    final e = _entries.remove(path);
    if (e != null) _bytes -= e.footprint;
  }

  void clear() {
    _entries.clear();
    _bytes = 0;
  }
}
