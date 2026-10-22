import 'dart:io';
import 'dart:typed_data';

import 'server_exchange.dart';

/// One cached response representation (RFC 9111). Stores the status, the
/// headers to replay, the body, when it was stored, its freshness lifetime,
/// and the `Vary`-named request-header values the entry is keyed on.
class CachedResponse {
  CachedResponse({
    required this.statusCode,
    required this.headers,
    required this.body,
    required this.storedAt,
    required this.freshness,
    required this.varyNames,
    required this.varyValues,
  });

  final int statusCode;
  final List<MapEntry<String, String>> headers;
  final Uint8List body;
  final DateTime storedAt;
  final Duration freshness;
  final List<String> varyNames;
  final Map<String, String?> varyValues;

  bool isFresh(DateTime now) => now.difference(storedAt) < freshness;

  int ageSeconds(DateTime now) {
    final s = now.difference(storedAt).inSeconds;
    return s < 0 ? 0 : s;
  }

  bool varyMatches(Map<String, String> requestHeaders) {
    for (final name in varyNames) {
      if (varyValues[name] != requestHeaders[name]) return false;
    }
    return true;
  }

  /// Approximate memory footprint for the LRU byte budget.
  int get sizeBytes => body.length + 512;
}

/// A per-worker in-memory response cache with an LRU byte budget. Stores one
/// representation per key (the latest); a `Vary` mismatch is treated as a miss.
class ResponseCache {
  ResponseCache({this.maxBytes = 64 * 1024 * 1024});

  final int maxBytes;
  int _bytes = 0;
  // Insertion/access order = LRU order.
  final Map<String, CachedResponse> _entries = {};

  int get length => _entries.length;
  int get bytes => _bytes;

  /// Returns a fresh, vary-matching entry (and marks it most-recently-used), or
  /// null. Stale entries are evicted on access.
  CachedResponse? get(String key, Map<String, String> requestHeaders) {
    final entry = _entries[key];
    if (entry == null) return null;
    if (!entry.isFresh(DateTime.now())) {
      _evict(key);
      return null;
    }
    if (!entry.varyMatches(requestHeaders)) return null;
    _entries.remove(key);
    _entries[key] = entry; // move to MRU
    return entry;
  }

  void put(String key, CachedResponse entry) {
    final old = _entries.remove(key);
    if (old != null) _bytes -= old.sizeBytes;
    _entries[key] = entry;
    _bytes += entry.sizeBytes;
    while (_bytes > maxBytes && _entries.isNotEmpty) {
      _evict(_entries.keys.first);
    }
  }

  void invalidate(String key) => _evict(key);
  void clear() {
    _entries.clear();
    _bytes = 0;
  }

  void _evict(String key) {
    final e = _entries.remove(key);
    if (e != null) _bytes -= e.sizeBytes;
  }
}

/// Parses a `Cache-Control` header into directive -> value (value is '' for
/// valueless directives, lower-cased names).
Map<String, String> parseCacheControl(String? header) {
  final out = <String, String>{};
  if (header == null) return out;
  for (final part in header.split(',')) {
    final token = part.trim();
    if (token.isEmpty) continue;
    final eq = token.indexOf('=');
    if (eq < 0) {
      out[token.toLowerCase()] = '';
    } else {
      final v = token.substring(eq + 1).trim();
      out[token.substring(0, eq).trim().toLowerCase()] =
          v.startsWith('"') && v.endsWith('"') && v.length >= 2
              ? v.substring(1, v.length - 1)
              : v;
    }
  }
  return out;
}

/// Returns the freshness lifetime if this response is safe to store in a
/// *shared* cache (RFC 9111 §3), or null when it must not be cached. Only
/// explicit freshness is honored (no heuristic caching).
Duration? sharedCacheFreshness({
  required String method,
  required int statusCode,
  required Map<String, String> responseHeaders, // lower-cased, joined
  required Map<String, String> requestHeaders, // lower-cased, joined
}) {
  if (method != 'GET' || statusCode != 200) return null;
  if (requestHeaders['authorization'] != null) return null;
  if ((requestHeaders['cache-control'] ?? '').toLowerCase().contains('no-store')) {
    return null;
  }
  if (responseHeaders['set-cookie'] != null) return null;
  final vary = responseHeaders['vary'];
  if (vary != null && vary.trim() == '*') return null;

  final cc = parseCacheControl(responseHeaders['cache-control']);
  if (cc.containsKey('no-store') ||
      cc.containsKey('private') ||
      cc.containsKey('no-cache')) {
    return null;
  }
  final sMaxAge = int.tryParse(cc['s-maxage'] ?? '');
  if (sMaxAge != null) return sMaxAge > 0 ? Duration(seconds: sMaxAge) : null;
  final maxAge = int.tryParse(cc['max-age'] ?? '');
  if (maxAge != null) return maxAge > 0 ? Duration(seconds: maxAge) : null;

  final expires = responseHeaders['expires'];
  if (expires != null) {
    try {
      final exp = HttpDate.parse(expires);
      final dateHeader = responseHeaders['date'];
      final date = dateHeader != null ? HttpDate.parse(dateHeader) : DateTime.now();
      final d = exp.difference(date);
      return d > Duration.zero ? d : null;
    } catch (_) {
      return null;
    }
  }
  return null;
}

/// A [ServerResponse] that forwards to [_inner] while capturing a cacheable
/// copy. Cacheability is decided once headers are known; only then (and only
/// if cacheable) is the body buffered. On close a cacheable response is handed
/// to [onStore].
class CachingResponse implements ServerResponse {
  CachingResponse({
    required this.inner,
    required this.method,
    required this.requestHeaders,
    required this.onStore,
  });

  final ServerResponse inner;
  final String method;
  final Map<String, String> requestHeaders;
  final void Function(CachedResponse entry) onStore;

  int _status = 200;
  final List<MapEntry<String, String>> _headers = [];
  final Map<String, String> _headerMap = {};
  final BytesBuilder _buf = BytesBuilder(copy: false);
  bool? _cacheable;
  Duration? _freshness;

  static const _skipOnReplay = {
    'age',
    'x-cache',
    'connection',
    'keep-alive',
    'transfer-encoding',
  };

  @override
  int get statusCode => _status;

  @override
  void setStatus(int statusCode, [String? reasonPhrase]) {
    _status = statusCode;
    inner.setStatus(statusCode, reasonPhrase);
  }

  @override
  void setHeader(String name, String value) {
    _headers.add(MapEntry(name, value));
    final k = name.toLowerCase();
    _headerMap[k] = _headerMap.containsKey(k) ? '${_headerMap[k]}, $value' : value;
    inner.setHeader(name, value);
  }

  void _decide() {
    if (_cacheable != null) return;
    _freshness = sharedCacheFreshness(
      method: method,
      statusCode: _status,
      responseHeaders: _headerMap,
      requestHeaders: requestHeaders,
    );
    _cacheable = _freshness != null;
    inner.setHeader('X-Cache', _cacheable! ? 'MISS' : 'BYPASS');
  }

  @override
  Future<void> addStream(Stream<List<int>> body) async {
    _decide();
    if (!_cacheable!) {
      await inner.addStream(body);
      return;
    }
    // Tee: buffer each chunk as the inner sink consumes it.
    await inner.addStream(body.map((chunk) {
      _buf.add(chunk);
      return chunk;
    }));
  }

  @override
  Future<void> close() async {
    _decide();
    await inner.close();
    if (_cacheable! && _freshness != null) {
      final varyNames = <String>[];
      final varyValues = <String, String?>{};
      final vary = _headerMap['vary'];
      if (vary != null) {
        for (final n in vary.split(',')) {
          final name = n.trim().toLowerCase();
          if (name.isEmpty) continue;
          varyNames.add(name);
          varyValues[name] = requestHeaders[name];
        }
      }
      onStore(CachedResponse(
        statusCode: _status,
        headers: [
          for (final h in _headers)
            if (!_skipOnReplay.contains(h.key.toLowerCase())) h,
        ],
        body: _buf.takeBytes(),
        storedAt: DateTime.now(),
        freshness: _freshness!,
        varyNames: varyNames,
        varyValues: varyValues,
      ));
    }
  }
}
