// Dartisan mail — a small mailer over a pluggable transport (the Laravel Mail
// analog). Ships pure-Dart transports: [ArrayTransport] (capture for tests) and
// [LogTransport] (dev). An SMTP transport can implement [MailTransport] later.
import 'dart:async';

import '../queue/queue.dart';

/// An email message. Provide [html] and/or [text].
class Message {
  Message({
    required this.to,
    required this.subject,
    this.html,
    this.text,
    this.from,
  });

  final String to;
  final String subject;
  final String? html;
  final String? text;
  final String? from;

  Map<String, Object?> toMap() => {
        'to': to,
        'subject': subject,
        if (from != null) 'from': from,
        if (html != null) 'html': html,
        if (text != null) 'text': text,
      };
}

/// Delivers a [Message]. Implement this for real transports (SMTP, API, ...).
abstract class MailTransport {
  FutureOr<void> send(Message message);
}

/// Captures sent messages in memory — for tests and assertions.
class ArrayTransport implements MailTransport {
  final List<Message> sent = [];
  @override
  void send(Message message) => sent.add(message);
}

/// Writes a one-line summary per message — for local development.
class LogTransport implements MailTransport {
  LogTransport([void Function(String line)? sink]) : _sink = sink ?? print;
  final void Function(String line) _sink;
  @override
  void send(Message message) =>
      _sink('[mail] to=${message.to} subject=${message.subject}');
}

/// Sends messages through a [MailTransport], immediately or via a [Queue].
class Mailer {
  Mailer(this.transport);
  final MailTransport transport;

  Future<void> send(Message message) async => transport.send(message);

  /// Enqueues [message] for background delivery on [queue].
  void queue(Message message, Queue queue) =>
      queue.push(_SendMailJob(this, message));
}

class _SendMailJob implements Job {
  _SendMailJob(this._mailer, this._message);
  final Mailer _mailer;
  final Message _message;
  @override
  Future<void> handle() => _mailer.send(_message);
}
