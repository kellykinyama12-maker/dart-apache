import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_apache/dart_apache.dart';
import 'package:test/test.dart';

/// A minimal in-process SMTP server for testing [SmtpTransport] over loopback.
class _FakeSmtp {
  _FakeSmtp(this._server) {
    _server.listen(_handle);
  }
  final ServerSocket _server;
  final result = Completer<Map<String, Object?>>();

  int get port => _server.port;

  static Future<_FakeSmtp> start() async =>
      _FakeSmtp(await ServerSocket.bind('127.0.0.1', 0));

  Future<void> close() => _server.close();

  void _handle(Socket socket) {
    final buf = <int>[];
    final dataLines = <String>[];
    var inData = false;
    var authStep = 0;
    String? from, to, user, pass;

    void reply(String s) => socket.add(utf8.encode(s));
    reply('220 fake-smtp ready\r\n');

    socket.listen((chunk) {
      for (final b in chunk) {
        if (b != 0x0a) {
          buf.add(b);
          continue;
        }
        var line = buf.toList();
        if (line.isNotEmpty && line.last == 0x0d) {
          line = line.sublist(0, line.length - 1);
        }
        buf.clear();
        final s = utf8.decode(line);
        if (inData) {
          if (s == '.') {
            inData = false;
            reply('250 queued\r\n');
            result.complete({
              'from': from,
              'to': to,
              'user': user,
              'pass': pass,
              'data': dataLines.join('\n'),
            });
          } else {
            dataLines.add(s.startsWith('..') ? s.substring(1) : s);
          }
          continue;
        }
        final up = s.toUpperCase();
        if (up.startsWith('EHLO')) {
          reply('250-fake hi\r\n250 AUTH LOGIN\r\n');
        } else if (up.startsWith('AUTH LOGIN')) {
          authStep = 1;
          reply('334 VXNlcm5hbWU6\r\n');
        } else if (authStep == 1) {
          user = utf8.decode(base64.decode(s));
          authStep = 2;
          reply('334 UGFzc3dvcmQ6\r\n');
        } else if (authStep == 2) {
          pass = utf8.decode(base64.decode(s));
          authStep = 0;
          reply('235 authenticated\r\n');
        } else if (up.startsWith('MAIL FROM')) {
          from = s;
          reply('250 ok\r\n');
        } else if (up.startsWith('RCPT TO')) {
          to = s;
          reply('250 ok\r\n');
        } else if (up == 'DATA') {
          inData = true;
          reply('354 end with <CRLF>.<CRLF>\r\n');
        } else if (up.startsWith('QUIT')) {
          reply('221 bye\r\n');
        } else {
          reply('250 ok\r\n');
        }
      }
    });
  }
}

void main() {
  group('SmtpTransport', () {
    test('authenticates and submits a plain message', () async {
      final smtp = await _FakeSmtp.start();
      final transport = SmtpTransport(
        host: '127.0.0.1',
        port: smtp.port,
        username: 'alice',
        password: 'secret',
        security: SmtpSecurity.none,
      );

      await Mailer(transport).send(Message(
        to: 'bob@example.org',
        from: 'alice@example.com',
        subject: 'Hello',
        text: 'Plain body',
      ));

      final r = await smtp.result.future.timeout(const Duration(seconds: 5));
      expect(r['user'], 'alice');
      expect(r['pass'], 'secret');
      expect(r['from'], contains('<alice@example.com>'));
      expect(r['to'], contains('<bob@example.org>'));
      final data = r['data'] as String;
      expect(data, contains('Subject: Hello'));
      expect(data, contains('To: bob@example.org'));
      expect(data, contains('Plain body'));
      await smtp.close();
    });

    test('sends multipart/alternative when text + html are given', () async {
      final smtp = await _FakeSmtp.start();
      final transport = SmtpTransport(
        host: '127.0.0.1',
        port: smtp.port,
        security: SmtpSecurity.none,
        defaultFrom: 'noreply@example.com',
      );

      await transport.send(Message(
        to: 'bob@example.org',
        subject: 'Rich',
        text: 'text part',
        html: '<p>html part</p>',
      ));

      final data =
          (await smtp.result.future.timeout(const Duration(seconds: 5)))['data']
              as String;
      expect(data, contains('multipart/alternative'));
      expect(data, contains('text/plain'));
      expect(data, contains('text part'));
      expect(data, contains('text/html'));
      expect(data, contains('<p>html part</p>'));
      await smtp.close();
    });

    test('dot-stuffs body lines beginning with a period', () async {
      final smtp = await _FakeSmtp.start();
      final transport = SmtpTransport(
        host: '127.0.0.1',
        port: smtp.port,
        security: SmtpSecurity.none,
        defaultFrom: 'a@b.c',
      );

      await transport.send(Message(
        to: 'x@y.z',
        subject: 'Dots',
        text: 'normal\r\n.hidden line\r\nend',
      ));

      final data =
          (await smtp.result.future.timeout(const Duration(seconds: 5)))['data']
              as String;
      // Server-side un-stuffing restores the original leading dot.
      expect(data, contains('.hidden line'));
      await smtp.close();
    });

    test('throws when no from address is available', () {
      final transport = SmtpTransport(host: '127.0.0.1', port: 1);
      expect(
        () => transport.send(Message(to: 'x@y.z', subject: 's', text: 't')),
        throwsStateError,
      );
    });
  });
}
