// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// B-28. Metadata is not paced, and that is CORRECT: flow control in HTTP/2
// applies to DATA only, and HEADERS are exempt precisely because a control frame
// that cannot be sent deadlocks the stream it is trying to end. `sendMetadata`
// spends no window and `_fcOnConsumed` returns early on zero bytes, both by
// design.
//
// What was missing is the other half. Round 282 measured 4000 metadata frames,
// 32 MiB, none paced AND no bound fired: the per-stream view from
// `getMessagesForStream` is a plain `StreamController`, unweighed and uncapped,
// so flow control was the only thing in front of it and metadata walks past
// flow control. An unbounded buffer reachable by an unauthenticated peer.
//
// The fix is a BUFFER bound, not a pacing one — which is also how the protocol
// bounds headers. The stream fails with RESOURCE_EXHAUSTED; the CONNECTION
// survives, because a peer flooding one call must not take down the others
// sharing the socket.
@TestOn('vm')
library;

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

/// Roughly 8 KiB of headers, the shape round 282 used.
RpcMetadata _headerBlock() =>
    RpcMetadata([for (var i = 0; i < 8; i++) RpcHeader('x-h$i', 'v' * 1024)]);

void main() {
  test('a metadata flood fails the STREAM, not the connection', () async {
    // Small enough to reach quickly, and it is the same knob the frame parser
    // already bounds itself with.
    const policy = RpcSecurityPolicy(maxBufferedBytes: 256 * 1024);
    final (client, server) = RpcChannelTransport.pair(policy: policy);
    addTearDown(() async {
      await client.close();
      await server.close();
    });

    final streamId = client.createStream();

    // A consumer that TAKES the stream and then stops reading, which is the
    // only shape that lets the buffer grow.
    final seen = <RpcTransportMessage>[];
    final errors = <Object>[];
    final sub = server
        .getMessagesForStream(streamId)
        .listen(seen.add, onError: errors.add);
    sub.pause();

    await client.sendMetadata(
      streamId,
      RpcMetadata([const RpcHeader(':path', '/Svc/sink')]),
    );
    for (var i = 0; i < 200; i++) {
      await client.sendMetadata(streamId, _headerBlock());
    }

    // Resume so whatever the transport decided can be observed. A paused
    // consumer cannot see its own error, which is why round 282's bench
    // reported "connection error: none" either way.
    sub.resume();
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(
      errors,
      isNotEmpty,
      reason:
          '200 metadata frames of ~8 KiB against a 256 KiB buffer bound were '
          'all accepted — the per-stream controller is unweighed and uncapped',
    );
    expect(
      errors.first,
      isA<RpcStatusException>().having(
        (e) => e.statusCode,
        'statusCode',
        RpcStatus.resourceExhausted,
      ),
    );

    // The CONNECTION survives: another stream on the same transport still works.
    expect(server.isClosed, isFalse);
    expect(client.isClosed, isFalse);

    await sub.cancel();
  });

  test('GUARD: an ordinary exchange is untouched', () async {
    // The bound must only refuse a flood. A normal call carries a handful of
    // metadata frames and has to keep working with the DEFAULT policy.
    final (client, server) = RpcChannelTransport.pair();
    addTearDown(() async {
      await client.close();
      await server.close();
    });

    final streamId = client.createStream();
    final seen = <RpcTransportMessage>[];
    final errors = <Object>[];
    final sub = server
        .getMessagesForStream(streamId)
        .listen(seen.add, onError: errors.add);

    await client.sendMetadata(
      streamId,
      RpcMetadata([const RpcHeader(':path', '/Svc/echo')]),
    );
    await client.sendMessage(streamId, Uint8List.fromList([1, 2, 3]));
    await client.sendMetadata(
      streamId,
      RpcMetadata.forTrailer(RpcStatus.ok),
      endStream: true,
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(errors, isEmpty, reason: 'an ordinary exchange must not be refused');
    expect(seen, isNotEmpty);

    await sub.cancel();
  });

  test('GUARD: a consumer that reads can take any number of frames', () async {
    // The bound is on what is BUFFERED, not on what is delivered. A consumer
    // keeping up must never hit it, however many frames arrive — otherwise this
    // is a throughput cap wearing a buffer's clothes.
    const policy = RpcSecurityPolicy(maxBufferedBytes: 256 * 1024);
    final (client, server) = RpcChannelTransport.pair(policy: policy);
    addTearDown(() async {
      await client.close();
      await server.close();
    });

    final streamId = client.createStream();
    var delivered = 0;
    final errors = <Object>[];
    final sub = server
        .getMessagesForStream(streamId)
        .listen((_) => delivered++, onError: errors.add);

    await client.sendMetadata(
      streamId,
      RpcMetadata([const RpcHeader(':path', '/Svc/sink')]),
    );
    for (var i = 0; i < 200; i++) {
      await client.sendMetadata(streamId, _headerBlock());
      // Let the consumer drain, which is what a real one does.
      await Future<void>.delayed(Duration.zero);
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(
      errors,
      isEmpty,
      reason:
          'a consumer that keeps up never buffers, so 200 frames of any size '
          'must pass',
    );
    expect(delivered, greaterThan(100));

    await sub.cancel();
  });
}
