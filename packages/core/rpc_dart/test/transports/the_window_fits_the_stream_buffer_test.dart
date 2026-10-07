// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The per-stream queue was bounded by `maxMessageLengthBytes + 5` while the
// sender was paced by a 4 MiB window. With a 64 KiB message limit, a stream of
// 60 KiB items to a reader slower than the producer failed with
// RESOURCE_EXHAUSTED at the third item, from a peer obeying flow control.
//
// Two rules close it. The derived queue bound covers what the window lets a
// peer send. And when `maxBufferedBytes` is set explicitly below that, the
// receiver advertises a window that fits it, so the stream slows down instead
// of failing. A third rule keeps the arithmetic honest: the peer's first grant
// replaces the initial send window instead of adding to it.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart/src/rpc/transports/flow_controller.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Svc extends RpcResponderContract {
  _Svc() : super('Svc');

  @override
  void setup() {
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'big',
      handler: (r, {RpcContext? context}) async* {
        for (var i = 0; i < 30; i++) {
          yield ('b' * (60 * 1024)).rpc;
        }
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

/// Streams 30 items of 60 KiB to a reader spending 10 ms on each.
Future<({int received, Object? error})> _slowRead(
  RpcSecurityPolicy policy,
) async {
  final (client, server) = RpcChannelTransport.pair(policy: policy);
  final responder = RpcResponderEndpoint(transport: server)
    ..registerServiceContract(_Svc());
  responder.start();
  final caller = RpcCallerEndpoint(transport: client);
  addTearDown(() async {
    await caller.close();
    await responder.close();
  });

  var received = 0;
  Object? error;
  try {
    await for (final _ in caller.serverStream<RpcString, RpcString>(
      serviceName: 'Svc',
      methodName: 'big',
      request: ''.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    )) {
      received++;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  } catch (e) {
    error = e;
  }
  return (received: received, error: error);
}

void main() {
  test('WITNESS a 64 KiB message limit under the default window', () async {
    final r = await _slowRead(
      const RpcSecurityPolicy(maxMessageLengthBytes: 64 * 1024),
    );

    expect(r.error, isNull);
    expect(r.received, 30);
  });

  test(
    'an explicit small buffer slows the stream instead of failing',
    () async {
      final r = await _slowRead(
        const RpcSecurityPolicy(
          maxMessageLengthBytes: 64 * 1024,
          maxBufferedBytes: 64 * 1024 + 5,
        ),
      );

      expect(r.error, isNull);
      expect(r.received, 30);
    },
  );

  group('the policy', () {
    test('the derived queue covers the window, a message and metadata', () {
      const p = RpcSecurityPolicy(maxMessageLengthBytes: 1000);

      expect(
        p.effectiveStreamBufferBytes,
        p.flowControlWindowBytes! + 1005 + p.maxMetadataBytes,
      );
      expect(p.advertisedWindowBytes, p.flowControlWindowBytes);
    });

    test('with the window off the queue is the message bound', () {
      const p = RpcSecurityPolicy(
        maxMessageLengthBytes: 1000,
        flowControlWindowBytes: null,
      );

      expect(p.effectiveStreamBufferBytes, 1005);
      expect(p.advertisedWindowBytes, isNull);
    });

    test('an explicit buffer shrinks the advertised window', () {
      const roomy = RpcSecurityPolicy(
        maxMessageLengthBytes: 1000,
        maxMetadataBytes: 100,
        maxBufferedBytes: 1105 + 5000,
      );
      const tight = RpcSecurityPolicy(
        maxMessageLengthBytes: 1000,
        maxBufferedBytes: 1005,
      );

      expect(roomy.advertisedWindowBytes, 5000);
      // No room for a maximal message on top: half the buffer.
      expect(tight.advertisedWindowBytes, 502);
    });

    test('a hardening buffer below the message limit keeps the window', () {
      // 8 MiB against the default 16 MiB message limit: half of it is the
      // default 4 MiB window, so nothing slows down.
      const p = RpcSecurityPolicy(maxBufferedBytes: 8 * 1024 * 1024);

      expect(p.advertisedWindowBytes, p.flowControlWindowBytes);
    });
  });

  test('the first grant replaces the initial send window', () {
    final fc = RpcFlowController(
      policy: const RpcSecurityPolicy(
        flowControlWindowBytes: 1000,
        initialSendWindowBytes: 400,
      ),
      send: (_, _) async {},
      isStreamLive: (_) => true,
    );
    fc.tryConsume(1, 300);

    fc.handleInbound(
      RpcTransportMessage.withMetadata(
        streamId: 1,
        metadata: RpcMetadata([
          RpcHeader(RpcHeaders.xWindowUpdate, '1000'),
          RpcHeader(RpcHeaders.xWindowUpdateMessages, '8'),
        ]),
      ),
    );

    // Added to the seed this would be 1000 (clamped from 1100), and the peer,
    // already holding 300, would be sent 1300.
    expect(fc.creditFor(1), 700);
  });

  test('the first connection grant replaces the initial send window', () {
    final fc = RpcFlowController(
      policy: const RpcSecurityPolicy(
        flowControlWindowBytes: null,
        flowControlConnectionWindowBytes: 1000,
        initialSendWindowBytes: 400,
      ),
      send: (_, _) async {},
      isStreamLive: (_) => true,
    );
    fc.tryConsume(1, 300);

    fc.handleInbound(
      RpcTransportMessage.withMetadata(
        streamId: RpcFlowController.connectionStreamId,
        metadata: RpcMetadata([
          RpcHeader(RpcHeaders.xConnWindowUpdate, '1000'),
        ]),
      ),
    );

    expect(fc.connectionCredit, 700);
  });
}
