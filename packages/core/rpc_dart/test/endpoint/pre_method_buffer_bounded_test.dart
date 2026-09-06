// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A payload frame whose method is not yet known is BUFFERED rather than
// dropped: on a broadcast transport the first DATA frame of a stream can be
// processed before its metadata frame, and dropping it loses the leading chunk.
// That buffer had no size limit, and it sits in the one window where nothing
// else bounds it either -- until a responder is bound no layer claims the
// stream, so RpcChannelTransport credits flow control ON ARRIVAL and the peer's
// window is replenished forever. maxActiveStreams does not apply (one id is
// enough), maxMessageLengthBytes does not either (every frame is individually
// legal), and halfOpenStreamTimeout bounds TIME, not VOLUME.
//
// Measured against a websocket server, a raw client pushing 4 KiB DATA frames
// at a single stream id it never opened with metadata:
//
//   pushed 250.7 MiB  ->  server RSS +495.2 MiB   (8113 B per 4 KiB frame)
//
// versus 28.8 MiB for the same volume at a stream the server had already
// answered, which is the drop path. Confirmed as the mechanism by re-running
// with halfOpenStreamTimeout: 300ms so the reclaim fires mid-flood: +56.2 MiB
// (921 B per frame). After the bound: +30.3 MiB (497 B per frame), and the
// per-frame cost now FALLS with scale (744 -> 497), which is allocation churn
// rather than retention.
//
// No rpc_dart client is needed to reach this -- three hand-built frames on a
// plain WebSocket do it -- so it was unauthenticated remote memory exhaustion
// for the length of the default 60s half-open window.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

/// Payloads the handler actually received, in arrival order.
List<String> _seen = [];

/// Small enough to fill quickly, large enough that a single 4 KiB frame is
/// itself legal -- otherwise the frame layer refuses first and the limit under
/// test is never consulted.
const _maxMessageBytes = 64 * 1024;
const _payloadBytes = 4 * 1024;

final class _Contract extends RpcResponderContract {
  _Contract() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'echo',
      handler: (request, {RpcContext? context}) async {
        _seen.add(request.value);
        return request;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

({
  RpcChannelTransport client,
  RpcChannelTransport server,
  RpcResponderEndpoint responder,
})
_connect() {
  final (clientCh, serverCh) = RpcFrameMultiplexedChannel.pair();
  final client = RpcChannelTransport(
    channel: clientCh,
    isClient: true,
    // Generous on the client: the peer is the thing being simulated, and its
    // own limits must not be what stops the flood.
    policy: const RpcSecurityPolicy(maxActiveStreams: 100000),
  );
  final server = RpcChannelTransport(
    channel: serverCh,
    isClient: false,
    policy: const RpcSecurityPolicy(
      maxMessageLengthBytes: _maxMessageBytes,
      maxActiveStreams: 100000,
    ),
  );
  final responder = RpcResponderEndpoint(transport: server);
  responder.registerServiceContract(_Contract());
  responder.start();
  return (client: client, server: server, responder: responder);
}

Uint8List _payload(String body) =>
    RpcMessageFrame.encode(_codec.serialize(body.rpc));

/// Collects the trailers the server sends back on [streamId].
Future<List<RpcMetadata>> _trailersOn(
  RpcChannelTransport client,
  Iterable<int> streamIds,
  Duration window,
) async {
  final ids = streamIds.toSet();
  final seen = <RpcMetadata>[];
  final sub = client.incomingMessages
      .where((m) => ids.contains(m.streamId) && m.metadata != null)
      .listen((m) => seen.add(m.metadata!));
  await Future<void>.delayed(window);
  await sub.cancel();
  return seen;
}

String? _status(RpcMetadata metadata) =>
    metadata.getHeaderValue(RpcHeaders.grpcStatus);

void main() {
  setUp(() => _seen = []);

  test(
    'payload for a stream with no method cannot be pushed without bound',
    () async {
      final c = _connect();

      // 12x the budget, all at ONE stream id that never gets a metadata frame.
      const frames = 200;
      final trailers = _trailersOn(c.client, const [
        99,
      ], const Duration(seconds: 2));
      for (var i = 0; i < frames; i++) {
        await c.client.sendMessage(99, _payload('x' * _payloadBytes));
      }
      final got = await trailers;

      final refusal = got.where(
        (m) => _status(m) == RpcStatus.resourceExhausted.toString(),
      );
      expect(
        refusal,
        isNotEmpty,
        reason:
            'the server absorbed ${frames * _payloadBytes ~/ 1024} KiB against a '
            '${_maxMessageBytes ~/ 1024} KiB budget without refusing',
      );
      // Name the control that fired: a refusal from some OTHER limit would be
      // just as green and would prove nothing about this one. grpc-message is
      // percent-encoded on the wire.
      expect(
        Uri.decodeComponent(
          refusal.first.getHeaderValue(RpcHeaders.grpcMessage) ?? '',
        ),
        contains('before the method was known'),
      );

      await c.responder.close();
      await c.client.close();
      await c.server.close();
    },
  );

  test('the budget is per connection, not per stream', () async {
    // Otherwise inventing more stream ids buys more budget, and the bound is
    // decorative: 200 ids x one frame each is under any per-stream cap.
    final c = _connect();

    final ids = [for (var i = 0; i < 200; i++) 1001 + i];
    final trailers = _trailersOn(c.client, ids, const Duration(seconds: 2));
    for (final id in ids) {
      await c.client.sendMessage(id, _payload('x' * _payloadBytes));
    }
    final got = await trailers;

    expect(
      got.where((m) => _status(m) == RpcStatus.resourceExhausted.toString()),
      isNotEmpty,
      reason: 'each new stream id got a fresh buffer budget',
    );

    await c.responder.close();
    await c.client.close();
    await c.server.close();
  });

  test('a frame that arrives before its metadata is still replayed', () async {
    // GUARD (passes both sides). This is the reason the buffer exists, and the
    // obvious wrong fix -- drop pre-method frames instead of bounding them --
    // would lose the leading chunk of a blob upload.
    final c = _connect();

    await c.client.sendMessage(7, _payload('leading-chunk'));
    await c.client.sendMetadata(7, RpcMetadata.forClientRequest('Svc', 'echo'));
    await c.client.finishSending(7);
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(
      _seen,
      contains('leading-chunk'),
      reason: 'the frame buffered before the method resolved was lost',
    );

    await c.responder.close();
    await c.client.close();
    await c.server.close();
  });

  test('the budget is returned as streams resolve', () async {
    // WITNESS for the release path, which is the half a wrong fix gets wrong:
    // a counter that only ever increments bounds the attack just as well, and
    // then silently starves the connection. 40 rounds x 4 KiB is 160 KiB
    // against a 64 KiB budget, so without the release the ceiling is reached
    // partway through and the REMAINING legitimate calls are refused.
    //
    // The payload has to be big for that: an earlier version sent 'round-$n'
    // (~17 bytes, 670 in total) and never came near the cap, so the call-count
    // assertion passed with the release disabled and proved nothing.
    final c = _connect();

    for (var round = 0; round < 40; round++) {
      final id = 11 + round * 2;
      await c.client.sendMessage(id, _payload('x' * _payloadBytes));
      await c.client.sendMetadata(
        id,
        RpcMetadata.forClientRequest('Svc', 'echo'),
      );
      await c.client.finishSending(id);
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(
      _seen.length,
      40,
      reason:
          'only ${_seen.length} of 40 reorder-opened calls ran; the pre-method '
          'budget is not being released',
    );
    // Assert the quantity itself, not just its downstream effect: the counter
    // must come back to zero, or the ceiling ratchets down over a connection's
    // lifetime and the refusals show up much later, on innocent traffic.
    expect(
      c.responder.collectEndpointMetrics()['preMethodBufferedBytes'],
      0,
      reason: 'the pre-method budget was never returned',
    );

    await c.responder.close();
    await c.client.close();
    await c.server.close();
  });
}
