// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The per-stream buffer ledger charged `bufferedBytes`, which is 0 for a
// `directPayload` — so a zero-copy peer could queue without limit against a paused
// consumer and nothing was ever charged for it.
//
// "Queuing a direct object costs a pointer" is true of exactly one shape. Measured
// with 400 objects of 1 MiB and a paused consumer: a queue of objects the
// application holds anyway costs `-33 MiB`, and minting one per message costs
// `270 MiB`. A queue DEPTH bounds both without having to tell them apart, which is
// why the new ceiling counts messages and never their contents.
//
// A sender doing flow control is granted the depth as message credit, so it
// parks there instead of passing it. A sender that ignores credit passes it, and
// the stream fails with RESOURCE_EXHAUSTED instead of growing.
//
// The measurements are in `.claude/loop/rounds/550` and `709`.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

/// A payload the transport carries by reference.
final class _Blob implements IRpcSerializable {
  _Blob(this.n);
  final int n;

  @override
  Map<String, dynamic> toJson() => {'n': n};
}

typedef _Run = ({int received, int sentWhilePaused, Object? error});

/// Sends [count] direct objects to a consumer that is paused for [pause], then
/// drains, and reports what arrived.
///
/// [meters] false gives the sender no flow control, so it takes no credit and
/// stands for a peer that ignores the grants.
Future<_Run> _send({
  required int count,
  required int depth,
  required bool pause,
  bool meters = true,
}) async {
  final (clientCh, serverCh) = RpcDirectMultiplexedChannel.pair();
  final client = RpcChannelTransport(
    channel: clientCh,
    isClient: true,
    policy: meters
        ? RpcSecurityPolicy(maxBufferedMessagesPerStream: depth)
        : RpcSecurityPolicy(
            maxBufferedMessagesPerStream: depth,
            flowControlWindowBytes: null,
            flowControlConnectionWindowBytes: null,
          ),
  );
  final server = RpcChannelTransport(
    channel: serverCh,
    isClient: false,
    policy: RpcSecurityPolicy(maxBufferedMessagesPerStream: depth),
  );
  addTearDown(() async {
    await client.close();
    await server.close();
  });

  final streamId = client.createStream();
  var received = 0;
  Object? error;
  final done = Completer<void>();
  final sub = server
      .getMessagesForStream(streamId)
      .listen(
        // Direct payloads only. The opening METADATA frame is routed to this same
        // controller and charged one event against the depth like any other
        // un-consumed message — correct, and not what these counts are about.
        (m) => m.isDirect ? received++ : null,
        onError: (Object e) {
          error ??= e;
          if (!done.isCompleted) done.complete();
        },
      );
  // The connection-wide broadcast is a DIFFERENT queue with its own bound; drained
  // so it cannot be what this test measures.
  final drain = server.incomingMessages.listen(null);
  addTearDown(() async {
    await sub.cancel();
    await drain.cancel();
  });

  if (pause) sub.pause();

  await client.sendMetadata(
    streamId,
    RpcMetadata.forClientRequest('Svc', 'push'),
  );
  var sent = 0;
  // Not awaited: a metered sender parks at the depth while the consumer is
  // paused, and that park is part of what is measured.
  final sending = () async {
    for (var i = 0; i < count; i++) {
      await client.sendDirectObject(streamId, _Blob(i));
      sent++;
    }
  }();

  var sentWhilePaused = 0;
  if (pause) {
    // Give the refusal a chance to land before resuming.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    sentWhilePaused = sent;
    sub.resume();
  }
  await sending.timeout(const Duration(seconds: 5));
  await Future<void>.delayed(const Duration(milliseconds: 100));
  return (received: received, sentWhilePaused: sentWhilePaused, error: error);
}

void main() {
  test(
    'WITNESS a metered sender parks at the depth of a paused consumer',
    () async {
      final r = await _send(count: 50, depth: 4, pause: true);

      expect(r.error, isNull);
      expect(
        r.sentWhilePaused,
        4,
        reason:
            'the depth is granted as message credit, so the sender stops there',
      );
      expect(r.received, 50, reason: 'and resumes when the consumer does');
    },
  );

  test('a sender ignoring credit cannot queue past the depth', () async {
    final r = await _send(count: 50, depth: 4, pause: true, meters: false);

    expect(
      r.error,
      isA<RpcStatusException>().having(
        (e) => e.statusCode,
        'statusCode',
        RpcStatus.resourceExhausted,
      ),
      reason:
          'a direct payload weighs 0 bytes, so the byte ledger admitted all 50 '
          'and charged nothing',
    );
    expect(
      r.error.toString(),
      contains('un-consumed messages'),
      reason:
          'the message must name the ceiling that fired: a count overflow '
          'reported as a byte overflow names a number the stream never reached',
    );
  });

  test('GUARD a consumer that keeps up receives everything', () async {
    // The depth bounds UN-CONSUMED messages, not messages. Without this the
    // witness would also pass on a transport that had simply stopped delivering.
    final r = await _send(count: 50, depth: 4, pause: false);

    expect(r.received, 50);
    expect(r.error, isNull);
  });

  test('GUARD a paused consumer within the depth is untouched', () async {
    final r = await _send(count: 3, depth: 4, pause: true);

    expect(r.received, 3);
    expect(r.error, isNull);
  });

  test('the ledger releases the count, or one stream works once', () async {
    // The event charge has to come back as the consumer takes each message. If it
    // did not, a stream would be admitted `depth` times and refused for ever
    // after — which the draining guard above cannot see, because it never pauses.
    final r = await _send(count: 20, depth: 4, pause: false);

    expect(
      r.received,
      20,
      reason: '20 > depth 4, so this only passes if the charge is released',
    );
  });
}
