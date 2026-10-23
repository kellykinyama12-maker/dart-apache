// SMTP submission transport for [Mailer] — pure `dart:io`, no dependencies.
// Speaks the subset of SMTP a mail-submission client needs: greeting, EHLO,
// optional STARTTLS, AUTH LOGIN/PLAIN, MAIL FROM / RCPT TO / DATA. For a full
// MTA (direct-MX delivery, DKIM, SPF/DMARC) swap in a richer MailTransport —
// e.g. the dart-email-server package — behind the same seam.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'mail.dart';

/// How the connection is secured.
enum SmtpSecurity {
  /// Plaintext (dev / loopback only).
  none,

  /// Upgrade a plaintext connection with `STARTTLS` (typical on port 587).
  starttls,

  /// TLS from the first byte (typical on port 465).
  implicit,
}

/// Thrown when the server returns an unexpected reply code.
class SmtpException implements Exception {
  SmtpException(this.code, this.message);
  final int code;
  final String message;
  @override
  String toString() => 'SmtpException($code): $message';
}

/// Sends mail by submitting it to an SMTP server (relay/smarthost).
class SmtpTransport implements MailTransport {
  SmtpTransport({
    required this.host,
    this.port = 587,
    this.username,
    this.password,
    this.security = SmtpSecurity.starttls,
    this.defaultFrom,
    this.ehloName = 'localhost',
    this.timeout = const Duration(seconds: 30),
    this.allowBadCertificate = false,
  });

  final String host;
  final int port;
  final String? username;
  final String? password;
  final SmtpSecurity security;

  /// Used as the envelope + `From:` when a [Message] omits `from`.
  final String? defaultFrom;
  final String ehloName;
  final Duration timeout;

  /// Accept self-signed/mismatched TLS certs (dev only).
  final bool allowBadCertificate;

  @override
  Future<void> send(Message message) async {
    final from = message.from ?? defaultFrom;
    if (from == null) {
      throw StateError('SmtpTransport: message has no "from" and no defaultFrom');
    }

    var socket = security == SmtpSecurity.implicit
        ? await SecureSocket.connect(host, port,
            timeout: timeout, onBadCertificate: _onBadCert)
        : await Socket.connect(host, port, timeout: timeout);

    final conn = _SmtpConnection(socket);
    try {
      await conn.expect(220);
      await conn.command('EHLO $ehloName', 250);

      if (security == SmtpSecurity.starttls) {
        await conn.command('STARTTLS', 220);
        socket = await SecureSocket.secure(socket,
            host: host, onBadCertificate: _onBadCert);
        conn.upgrade(socket);
        await conn.command('EHLO $ehloName', 250);
      }

      if (username != null && password != null) {
        await _authLogin(conn, username!, password!);
      }

      await conn.command('MAIL FROM:<${_addr(from)}>', 250);
      for (final rcpt in _recipients(message.to)) {
        await conn.command('RCPT TO:<$rcpt>', 250);
      }
      await conn.command('DATA', 354);
      await conn.writeData(_buildMessage(message, from));
      await conn.expect(250);
      await conn.command('QUIT', 221, ignoreErrors: true);
    } finally {
      socket.destroy();
    }
  }

  bool _onBadCert(X509Certificate _) => allowBadCertificate;

  Future<void> _authLogin(
      _SmtpConnection conn, String user, String pass) async {
    await conn.command('AUTH LOGIN', 334);
    await conn.command(base64.encode(utf8.encode(user)), 334);
    await conn.command(base64.encode(utf8.encode(pass)), 235);
  }

  static String _addr(String address) {
    // Accept "Name <addr>" or bare "addr".
    final lt = address.indexOf('<');
    if (lt >= 0 && address.endsWith('>')) {
      return address.substring(lt + 1, address.length - 1).trim();
    }
    return address.trim();
  }

  static List<String> _recipients(String to) =>
      to.split(',').map((r) => _addr(r)).where((r) => r.isNotEmpty).toList();

  static String _buildMessage(Message m, String from) {
    final headers = StringBuffer()
      ..write('From: $from\r\n')
      ..write('To: ${m.to}\r\n')
      ..write('Subject: ${m.subject}\r\n')
      ..write('Date: ${HttpDate.format(DateTime.now().toUtc())}\r\n')
      ..write('Message-ID: <${DateTime.now().microsecondsSinceEpoch}'
          '@$_messageIdHost>\r\n')
      ..write('MIME-Version: 1.0\r\n');

    final text = m.text;
    final html = m.html;
    final body = StringBuffer();
    if (text != null && html != null) {
      const boundary = 'dartisan-boundary-7f3a';
      headers.write(
          'Content-Type: multipart/alternative; boundary="$boundary"\r\n\r\n');
      body
        ..write('--$boundary\r\n')
        ..write('Content-Type: text/plain; charset=utf-8\r\n\r\n')
        ..write('$text\r\n')
        ..write('--$boundary\r\n')
        ..write('Content-Type: text/html; charset=utf-8\r\n\r\n')
        ..write('$html\r\n')
        ..write('--$boundary--\r\n');
    } else if (html != null) {
      headers.write('Content-Type: text/html; charset=utf-8\r\n\r\n');
      body.write('$html\r\n');
    } else {
      headers.write('Content-Type: text/plain; charset=utf-8\r\n\r\n');
      body.write('${text ?? ''}\r\n');
    }
    return headers.toString() + body.toString();
  }

  static const String _messageIdHost = 'dartisan.local';
}

/// Line-oriented SMTP reply reader + command writer over a (possibly upgraded)
/// socket.
class _SmtpConnection {
  _SmtpConnection(this._socket) {
    _bind();
  }

  Socket _socket;
  late StreamSubscription<List<int>> _sub;
  final _buffer = <int>[];
  final _lines = StreamController<String>();
  late StreamIterator<String> _reader;

  void _bind() {
    _reader = StreamIterator<String>(_lines.stream);
    _sub = _socket.listen(_onData,
        onError: _lines.addError, onDone: () {}, cancelOnError: true);
  }

  // Swap in the TLS socket after STARTTLS (keep the same line stream).
  void upgrade(Socket secure) {
    _sub.cancel();
    _socket = secure;
    _sub = _socket.listen(_onData,
        onError: _lines.addError, onDone: () {}, cancelOnError: true);
  }

  void _onData(List<int> data) {
    for (final b in data) {
      if (b == 0x0a) {
        var line = _buffer;
        if (line.isNotEmpty && line.last == 0x0d) {
          line = line.sublist(0, line.length - 1);
        }
        _lines.add(utf8.decode(line));
        _buffer.clear();
      } else {
        _buffer.add(b);
      }
    }
  }

  /// Reads one reply (handling multi-line `250-...` continuations) and checks
  /// its code against [expected].
  Future<void> expect(int expected) async {
    int? code;
    for (;;) {
      if (!await _reader.moveNext()) {
        throw SmtpException(0, 'connection closed awaiting $expected');
      }
      final line = _reader.current;
      if (line.length < 3) continue;
      code = int.tryParse(line.substring(0, 3));
      final continued = line.length > 3 && line[3] == '-';
      if (!continued) break;
    }
    if (code != expected) {
      throw SmtpException(code ?? 0, 'expected $expected');
    }
  }

  Future<void> command(String line, int expected,
      {bool ignoreErrors = false}) async {
    _socket.add(utf8.encode('$line\r\n'));
    await _socket.flush();
    if (ignoreErrors) {
      try {
        await expect(expected);
      } on Object {
        // best-effort (e.g. QUIT)
      }
    } else {
      await expect(expected);
    }
  }

  Future<void> writeData(String message) async {
    // Dot-stuff lines that begin with '.', terminate with <CRLF>.<CRLF>.
    final stuffed = message
        .split('\r\n')
        .map((l) => l.startsWith('.') ? '.$l' : l)
        .join('\r\n');
    _socket.add(utf8.encode(stuffed));
    if (!stuffed.endsWith('\r\n')) _socket.add(utf8.encode('\r\n'));
    _socket.add(utf8.encode('.\r\n'));
    await _socket.flush();
  }
}
