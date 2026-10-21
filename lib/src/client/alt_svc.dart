/// A discovered HTTP/3 alternative service (from an `Alt-Svc` header).
class H3AltService {
  H3AltService({
    required this.host,
    required this.port,
    required this.expiry,
  });

  /// Host to reach h3 on (defaults to the origin host when the authority is
  /// just `:port`).
  final String host;

  /// UDP port for QUIC/HTTP-3.
  final int port;

  /// When this advertisement should be considered stale.
  final DateTime expiry;

  bool get isFresh => expiry.isAfter(DateTime.now());
}

/// Parses an `Alt-Svc` header value and returns the first HTTP/3 (`h3`)
/// alternative, or null if none is advertised. [defaultHost] is used when the
/// advertised authority omits the host (e.g. `h3=":4433"`).
///
/// Example input: `h3=":4433"; ma=86400, h3-29=":4433"; ma=3600`.
H3AltService? parseAltSvcH3(String headerValue, String defaultHost) {
  // `clear` means drop all alternatives.
  if (headerValue.trim().toLowerCase() == 'clear') return null;

  for (final entry in _splitTopLevel(headerValue, ',')) {
    final params = _splitTopLevel(entry, ';').map((p) => p.trim()).toList();
    if (params.isEmpty) continue;

    final first = params.first;
    final eq = first.indexOf('=');
    if (eq < 0) continue;
    final protocol = first.substring(0, eq).trim().toLowerCase();
    if (protocol != 'h3') continue; // only accept final h3 (not drafts)

    final authority = _unquote(first.substring(eq + 1).trim());
    final colon = authority.lastIndexOf(':');
    if (colon < 0) continue;
    final host = colon == 0 ? defaultHost : authority.substring(0, colon);
    final port = int.tryParse(authority.substring(colon + 1));
    if (port == null) continue;

    var maxAge = 86400; // RFC 7838 default
    for (final param in params.skip(1)) {
      final pe = param.indexOf('=');
      if (pe < 0) continue;
      if (param.substring(0, pe).trim().toLowerCase() == 'ma') {
        maxAge = int.tryParse(param.substring(pe + 1).trim()) ?? maxAge;
      }
    }

    return H3AltService(
      host: host,
      port: port,
      expiry: DateTime.now().add(Duration(seconds: maxAge)),
    );
  }
  return null;
}

/// Splits on [sep] but ignores separators inside double quotes.
List<String> _splitTopLevel(String input, String sep) {
  final parts = <String>[];
  final buf = StringBuffer();
  var inQuotes = false;
  for (var i = 0; i < input.length; i++) {
    final ch = input[i];
    if (ch == '"') inQuotes = !inQuotes;
    if (ch == sep && !inQuotes) {
      parts.add(buf.toString());
      buf.clear();
    } else {
      buf.write(ch);
    }
  }
  parts.add(buf.toString());
  return parts;
}

String _unquote(String s) {
  if (s.length >= 2 && s.startsWith('"') && s.endsWith('"')) {
    return s.substring(1, s.length - 1);
  }
  return s;
}
