import 'dart:async';

import 'package:dart_apache/dart_apache.dart';
import 'package:test/test.dart';

class UserRegistered {
  UserRegistered(this.email);
  final String email;
}

class OrderShipped {
  OrderShipped(this.id);
  final int id;
}

class _RecordingJob implements Job {
  _RecordingJob(this.log, this.label);
  final List<String> log;
  final String label;
  @override
  void handle() => log.add(label);
}

class _FlakyJob implements Job {
  _FlakyJob(this.failUntil);
  final int failUntil;
  int attempts = 0;
  @override
  void handle() {
    attempts++;
    if (attempts < failUntil) throw StateError('boom');
  }
}

void main() {
  group('EventDispatcher', () {
    test('delivers an event to listeners of its type only', () async {
      final events = EventDispatcher();
      final seen = <String>[];
      events.listen<UserRegistered>((e) => seen.add('a:${e.email}'));
      events.listen<UserRegistered>((e) => seen.add('b:${e.email}'));
      events.listen<OrderShipped>((e) => seen.add('order:${e.id}'));

      await events.dispatch(UserRegistered('ada@x.io'));
      expect(seen, ['a:ada@x.io', 'b:ada@x.io']);
    });

    test('awaits async listeners', () async {
      final events = EventDispatcher();
      var done = false;
      events.listen<OrderShipped>((e) async {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        done = true;
      });
      await events.dispatch(OrderShipped(1));
      expect(done, isTrue);
    });

    test('dispatch with no listeners is a no-op', () async {
      await EventDispatcher().dispatch(OrderShipped(1));
    });

    test('hasListeners and forget', () {
      final events = EventDispatcher()..listen<OrderShipped>((_) {});
      expect(events.hasListeners<OrderShipped>(), isTrue);
      events.forget<OrderShipped>();
      expect(events.hasListeners<OrderShipped>(), isFalse);
    });
  });

  group('Queue', () {
    test('drains pushed jobs in FIFO order', () async {
      final log = <String>[];
      final q = Queue();
      q.push(_RecordingJob(log, 'one'));
      q.push(_RecordingJob(log, 'two'));
      q.push(_RecordingJob(log, 'three'));
      await q.settle();
      expect(log, ['one', 'two', 'three']);
    });

    test('CallbackJob runs a closure', () async {
      var ran = false;
      final q = Queue()..push(CallbackJob(() => ran = true));
      await q.settle();
      expect(ran, isTrue);
    });

    test('retries up to maxAttempts then succeeds', () async {
      final q = Queue(maxAttempts: 3);
      final job = _FlakyJob(3);
      q.push(job);
      await q.settle();
      expect(job.attempts, 3);
    });

    test('calls onFailed after exhausting attempts', () async {
      Job? failed;
      final q = Queue(maxAttempts: 2, onFailed: (j, e, s) => failed = j);
      final job = _FlakyJob(99);
      q.push(job);
      await q.settle();
      expect(job.attempts, 2);
      expect(identical(failed, job), isTrue);
    });

    test('delayed jobs run after the delay', () async {
      final log = <String>[];
      final q = Queue();
      q.push(_RecordingJob(log, 'later'),
          delay: const Duration(milliseconds: 20));
      expect(log, isEmpty); // not yet
      await Future<void>.delayed(const Duration(milliseconds: 40));
      await q.settle();
      expect(log, ['later']);
    });
  });

  group('Mail', () {
    test('ArrayTransport captures messages', () async {
      final transport = ArrayTransport();
      final mailer = Mailer(transport);
      await mailer.send(Message(
          to: 'ada@x.io', subject: 'Hi', html: '<p>Welcome</p>'));
      expect(transport.sent, hasLength(1));
      expect(transport.sent.single.to, 'ada@x.io');
      expect(transport.sent.single.subject, 'Hi');
    });

    test('LogTransport writes a one-line summary', () async {
      final lines = <String>[];
      final mailer = Mailer(LogTransport(lines.add));
      await mailer.send(Message(to: 'bob@x.io', subject: 'Receipt'));
      expect(lines.single, contains('to=bob@x.io'));
      expect(lines.single, contains('subject=Receipt'));
    });

    test('queued mail is delivered via the queue', () async {
      final transport = ArrayTransport();
      final mailer = Mailer(transport);
      final q = Queue();
      mailer.queue(Message(to: 'c@x.io', subject: 'Queued'), q);
      expect(transport.sent, isEmpty); // deferred
      await q.settle();
      expect(transport.sent.single.subject, 'Queued');
    });

    test('Message.toMap includes only provided fields', () {
      final map = Message(to: 't', subject: 's', text: 'body').toMap();
      expect(map, {'to': 't', 'subject': 's', 'text': 'body'});
    });
  });
}
