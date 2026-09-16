// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Flow control had NO logger at all before these: the channel-transport family
// (websocket, isolate, wasm) was silent about every event below, while the
// http2 sibling already reported its own version of the buffer overrun at
// `warning`.
//
// Levels are asserted, not just presence. The distinction is load-bearing:
// dropping the initial window because a peer never granted turns the bound OFF
// for the whole connection and cannot be inferred from anything else, so it is
// a warning; a park is per-send and must stay behind the `isInternal` guard or
// it costs a string on the hot path.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart/src/rpc/transports/flow_controller.dart';
import 'package:test/test.dart';

final class _Capture {
  _Capture({RpcLogLevel minLevel = RpcLogLevel.internal})
    : controller = LogController(minLevel: minLevel) {
    controller.stream.listen(records.add);
  }

  final LogController controller;
  final List<LogRecord> records = [];

  LogScope get scope => controller.scope('Fc');

  Iterable<LogEvent> get events => records.whereType<LogEvent>();

  Iterable<LogEvent> at(RpcLogLevel level) =>
      events.where((r) => r.level == level);

  Iterable<String> messagesAt(RpcLogLevel level) =>
      at(level).map((r) => r.message);
}

RpcTransportMessage _grant(int streamId, String value) =>
    RpcTransportMessage.withMetadata(
      streamId: streamId,
      metadata: RpcMetadata([RpcHeader(RpcHeaders.xWindowUpdate, value)]),
    );

void main() {
  late _Capture log;
  late List<(int, RpcMetadata)> sent;

  setUp(() {
    log = _Capture();
    sent = [];
  });

  RpcFlowController build(RpcSecurityPolicy policy, {LogScope? logger}) =>
      RpcFlowController(
        policy: policy,
        send: (id, metadata) async => sent.add((id, metadata)),
        isStreamLive: (_) => true,
        logger: logger ?? log.scope,
      );

  const bare = RpcSecurityPolicy(
    flowControlWindowBytes: 1000,
    flowControlConnectionWindowBytes: 1000,
    initialSendWindowBytes: null,
    initialSendWindowGrace: null,
  );

  test('dropping the window for a silent peer is a WARNING', () async {
    final fc = build(
      const RpcSecurityPolicy(
        flowControlWindowBytes: 1000,
        flowControlConnectionWindowBytes: 1000,
        initialSendWindowBytes: 100,
        initialSendWindowGrace: Duration(milliseconds: 50),
      ),
    );
    expect(fc.tryConsume(1, 100), isTrue);
    unawaited(fc.awaitCredit(1, 10));

    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(
      log.messagesAt(RpcLogLevel.warning),
      contains(allOf(contains('not doing flow control'), contains('window'))),
      reason: 'an operator cannot infer this from anything else',
    );
    fc.close();
  });

  // Records reach `LogController.stream` on a microtask, so every assertion
  // below waits one turn. A synchronous read sees an empty list on working
  // code, which is the most convincing way to write a test that never fails.
  test('a clamped grant is reported ONCE, not once per grant', () async {
    final fc = build(bare);

    for (var i = 0; i < 5; i++) {
      fc.handleInbound(_grant(1, '999999999'));
    }
    await Future<void>.delayed(Duration.zero);

    expect(
      log.messagesAt(RpcLogLevel.warning).where((m) => m.contains('clamping')),
      hasLength(1),
      reason: 'a peer that over-grants does so on every frame',
    );
  });

  test('a grant within our window says nothing', () async {
    final fc = build(bare);
    fc.handleInbound(_grant(1, '500'));
    await Future<void>.delayed(Duration.zero);

    expect(log.at(RpcLogLevel.warning), isEmpty);
  });

  test('the tracking cap is reported once', () async {
    final fc = build(
      const RpcSecurityPolicy(
        maxActiveStreams: 1,
        flowControlWindowBytes: 1000,
        flowControlConnectionWindowBytes: null,
        initialSendWindowBytes: null,
        initialSendWindowGrace: null,
      ),
    );

    fc.handleInbound(_grant(1, '100'));
    fc.handleInbound(_grant(3, '100'));
    fc.handleInbound(_grant(5, '100'));
    await Future<void>.delayed(Duration.zero);

    expect(
      log.messagesAt(RpcLogLevel.warning).where((m) => m.contains('cap')),
      hasLength(1),
    );
  });

  group('a park is internal-level and guarded', () {
    test('it is recorded when internal passes the filter', () async {
      final fc = build(bare);
      fc.handleInbound(_grant(1, '1000'));
      expect(fc.tryConsume(1, 1000), isTrue);

      unawaited(fc.awaitCredit(1, 10));
      await Future<void>.delayed(Duration.zero);

      expect(
        log.messagesAt(RpcLogLevel.internal),
        contains(contains('parked on 10 bytes')),
      );
      fc.close();
    });

    test('the release is recorded with how many parks it took', () async {
      final fc = build(bare);
      fc.handleInbound(_grant(1, '1000'));
      expect(fc.tryConsume(1, 1000), isTrue);

      unawaited(fc.awaitCredit(1, 10));
      await Future<void>.delayed(Duration.zero);
      fc.handleInbound(_grant(1, '1000'));
      await Future<void>.delayed(Duration.zero);

      expect(
        log.messagesAt(RpcLogLevel.internal),
        contains(contains('after 1 park(s)')),
      );
    });

    test('a send that does NOT park is silent', () {
      final fc = build(bare);
      fc.handleInbound(_grant(1, '1000'));

      expect(fc.tryConsume(1, 10), isTrue);
      expect(
        log.messagesAt(RpcLogLevel.internal).where((m) => m.contains('park')),
        isEmpty,
        reason: 'the unparked path is the hot one',
      );
    });

    test('nothing is emitted when the filter discards internal', () async {
      // This pins the FILTER, not the `isInternal` guard beside these calls --
      // measured: removing the guard leaves all ten tests here green, because
      // the controller discards the record either way. What the guard saves is
      // building the string, and nothing on the record stream can see that.
      //
      // So it is held by convention and review, not by this file. Said out
      // loud because a test named for a guard it does not reach is worse than
      // no test: it retires the question.
      final quiet = _Capture(minLevel: RpcLogLevel.warning);
      final fc = build(bare, logger: quiet.scope);
      fc.handleInbound(_grant(1, '1000'));
      expect(fc.tryConsume(1, 1000), isTrue);

      unawaited(fc.awaitCredit(1, 10));
      await Future<void>.delayed(Duration.zero);

      expect(quiet.at(RpcLogLevel.internal), isEmpty);
      fc.close();
    });
  });

  test('a late grant for a dead stream is reported at internal', () async {
    final fc = RpcFlowController(
      policy: bare,
      send: (id, metadata) async => sent.add((id, metadata)),
      isStreamLive: (_) => false,
      logger: log.scope,
    );

    fc.handleInbound(_grant(9, '500'));
    await Future<void>.delayed(Duration.zero);

    expect(
      log.messagesAt(RpcLogLevel.internal),
      contains(contains('the call has ended')),
    );
  });

  test('no logger at all is a supported configuration', () {
    final fc = RpcFlowController(
      policy: bare,
      send: (id, metadata) async => sent.add((id, metadata)),
      isStreamLive: (_) => true,
    );

    expect(() => fc.handleInbound(_grant(1, '999999999')), returnsNormally);
    expect(fc.creditFor(1), 1000);
  });
}
