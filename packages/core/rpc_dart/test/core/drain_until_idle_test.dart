// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Round 309 extracted three servers' drain loops into `drainUntilIdle` and
// reported the change with the caveat "nothing automated reads log levels".
//
// That was wrong, and round 313 is the correction: `LogController` exposes a
// broadcast `stream` of `LogRecord`, and `LogScope` is built from it. The
// levels ARE readable, so the unification is pinnable — which matters, because
// the whole finding in 309 was a LOGGING drift:
//
//     websocket  info   start, no success line
//     http       debug  start, no success line
//     http2      info   start, "Drain complete"
//
// An operator watching an HTTP/1.1 deploy at the default level saw nothing, and
// on two of three servers a drain's only possible line was "budget expired".
// These tests pin the three behaviours the shared implementation now gives all
// of them.

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

/// Records the controller emits, in order.
final class _Capture {
  _Capture() : controller = LogController(minLevel: RpcLogLevel.debug) {
    controller.stream.listen(records.add);
  }

  final LogController controller;
  final List<LogRecord> records = [];

  LogScope get scope => controller.scope('Drain');

  /// `LogRecord` is sealed over events and spans; only [LogEvent] carries a
  /// level and a message.
  Iterable<LogEvent> get events => records.whereType<LogEvent>();

  Iterable<LogEvent> at(RpcLogLevel level) =>
      events.where((r) => r.level == level);
}

void main() {
  test(
    'a drain with nothing in flight says nothing and returns at once',
    () async {
      final cap = _Capture();
      final started = DateTime.now();

      await drainUntilIdle(
        pending: () => 0,
        budget: const Duration(seconds: 5),
        logger: cap.scope,
      );

      // No poll, no wait: an idle server must not pay the 25 ms tick.
      expect(
        DateTime.now().difference(started),
        lessThan(const Duration(milliseconds: 200)),
      );
      // And no log line. A drain that had nothing to do is not an event.
      await Future<void>.delayed(Duration.zero);
      expect(cap.events, isEmpty);
    },
  );

  test('a drain that converges reports it at INFO', () async {
    final cap = _Capture();
    var remaining = 3;

    await drainUntilIdle(
      pending: () {
        final now = remaining;
        if (remaining > 0) remaining--;
        return now;
      },
      budget: const Duration(seconds: 5),
      logger: cap.scope,
      unit: 'call',
    );

    await Future<void>.delayed(Duration.zero);
    final info = cap.at(RpcLogLevel.info).map((r) => r.message).toList();

    // The START line, at INFO — the level http used to emit at DEBUG, so an
    // operator at the default level saw no drain at all.
    expect(
      info.any((m) => m.contains('Draining 3 in-flight call(s)')),
      isTrue,
      reason: 'no INFO start line; records: $info',
    );
    // The SUCCESS line — which two of the three servers never had, so a
    // converged drain was signalled by an absence.
    expect(
      info.any((m) => m.contains('Drain complete')),
      isTrue,
      reason: 'a converged drain reported nothing; records: $info',
    );
    expect(cap.at(RpcLogLevel.warning), isEmpty);
  });

  test('a drain that expires warns and still returns', () async {
    final cap = _Capture();

    await drainUntilIdle(
      // Never reaches zero: this is the peer that keeps calling, or the handler
      // that simply runs long.
      pending: () => 7,
      budget: const Duration(milliseconds: 150),
      logger: cap.scope,
      unit: 'request',
    );

    await Future<void>.delayed(Duration.zero);
    final warnings = cap.at(RpcLogLevel.warning).map((r) => r.message).toList();

    expect(
      warnings.any(
        (m) =>
            m.contains('expired') &&
            m.contains('7 request(s)') &&
            m.contains('closing anyway'),
      ),
      isTrue,
      reason: 'the expiry was not reported; records: $warnings',
    );
    // The budget is a ceiling, not a suggestion: it returned rather than
    // waiting for a count that never falls.
    expect(cap.at(RpcLogLevel.info).length, 1);
  });

  test('the unit names what is counted', () async {
    final cap = _Capture();
    await drainUntilIdle(
      pending: () => 2,
      budget: const Duration(milliseconds: 100),
      logger: cap.scope,
      unit: 'request',
    );

    await Future<void>.delayed(Duration.zero);
    final all = cap.events.map((r) => r.message).join('\n');
    expect(all, contains('request(s)'));
    expect(all, isNot(contains('call(s)')));
  });
}
