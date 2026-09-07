// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Audit finding C1. RpcSecurityPolicy.validateMetadata ran only in
// RpcChannelTransport.sendMetadata -- the OUTBOUND path -- so the limits
// constrained this side's own honest sender and never the untrusted peer,
// which is backwards for a security control.
//
// Measured before the fix, injecting at the frame layer as a foreign
// implementation would, with maxHeaders: 4 / maxHeaderValueBytes: 16:
//
//     inbound frames=1 errors=0
//     DELIVERED headers=200, first value length=500
//
// Affects every transport built on RpcChannelTransport + the frame channel
// (websocket, isolate). The HTTP/2 and HTTP responders already validated
// inbound.
//
// The tests write on the raw frame channel on purpose: routing through
// RpcChannelTransport.sendMetadata would hit the sender-side check and prove
// nothing about what a foreign peer can do.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

/// Metadata a cooperating sender would never build.
///
/// Deliberately small in TOTAL bytes (~7KB) so it stays under the separate
/// maxMetadataBytes frame cap: these tests must fail or pass on the header
/// count and value length alone, not on the payload-size check. The figure
/// measured before the fix used 200 x 500B, which trips both.
RpcMetadata _hostile({int headers = 200, int valueLength = 20}) => RpcMetadata([
  for (var i = 0; i < headers; i++) RpcHeader('h$i', 'x' * valueLength),
], methodPath: '/S/M');

/// A receiving transport plus the raw channel a hostile peer writes on.
({RpcChannelTransport server, IRpcMultiplexedChannel peer}) _pair(
  RpcSecurityPolicy policy,
) {
  final (peerChannel, serverChannel) = RpcFrameMultiplexedChannel.pair(
    policy: policy,
  );
  return (
    server: RpcChannelTransport(
      channel: serverChannel,
      isClient: false,
      policy: policy,
    ),
    peer: peerChannel,
  );
}

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 100));

void main() {
  const strict = RpcSecurityPolicy(maxHeaders: 4, maxHeaderValueBytes: 16);

  test('peer metadata over the policy is rejected, not delivered', () async {
    final p = _pair(strict);
    final delivered = <RpcTransportMessage>[];
    final errors = <Object>[];
    p.server.incomingMessages.listen(delivered.add, onError: errors.add);

    await p.peer.send(
      RpcTransportMessage.withMetadata(metadata: _hostile(), streamId: 1),
    );
    await _settle();

    expect(
      delivered,
      isEmpty,
      reason: 'peer metadata over maxHeaders/maxHeaderValueBytes was delivered',
    );
    expect(errors.single, isA<RpcFrameException>());

    await p.peer.close();
  });

  test('closeOnProtocolError tears the transport down', () async {
    final p = _pair(strict);
    p.server.incomingMessages.listen((_) {}, onError: (Object _) {});

    await p.peer.send(
      RpcTransportMessage.withMetadata(metadata: _hostile(), streamId: 1),
    );
    await _settle();

    expect(
      p.server.isClosed,
      isTrue,
      reason:
          'closeOnProtocolError defaults to true but was never honoured '
          'anywhere in the codebase before this fix',
    );

    await p.peer.close();
  });

  test('a violation is dropped, not fatal, when the flag is off', () async {
    final p = _pair(
      const RpcSecurityPolicy(
        maxHeaders: 4,
        maxHeaderValueBytes: 16,
        closeOnProtocolError: false,
      ),
    );
    final errors = <Object>[];
    p.server.incomingMessages.listen((_) {}, onError: errors.add);

    await p.peer.send(
      RpcTransportMessage.withMetadata(metadata: _hostile(), streamId: 1),
    );
    await _settle();

    expect(errors.single, isA<RpcFrameException>());
    expect(p.server.isClosed, isFalse);

    await p.peer.close();
    await p.server.close();
  });

  test('WITNESS: a lenient server still ANSWERS the refused stream', () async {
    // Dropping the frame without closing left the peer waiting for a response
    // that would never come: measured, the server sent nothing at all and the
    // connection stayed healthy. gRPC's rule, and a70c4799's on the http2
    // responder, is that every request gets a status.
    final p = _pair(
      const RpcSecurityPolicy(
        maxHeaders: 4,
        maxHeaderValueBytes: 16,
        closeOnProtocolError: false,
      ),
    );
    // Stream 0 carries connection-level flow control, which the transport
    // advertises from its constructor; only call-scoped frames count here.
    final answers = <RpcTransportMessage>[];
    p.peer.incoming
        .where((m) => m.streamId != 0)
        .listen(answers.add, onError: (Object _) {});
    p.server.incomingMessages.listen((_) {}, onError: (Object _) {});

    await p.peer.send(
      RpcTransportMessage.withMetadata(metadata: _hostile(), streamId: 1),
    );
    await _settle();

    expect(
      answers,
      hasLength(1),
      reason: 'the peer was told nothing and would wait for its deadline',
    );
    expect(
      answers.single.metadata?.getHeaderValue(RpcHeaders.grpcStatus),
      RpcStatus.invalidArgument.toString(),
    );
    expect(answers.single.streamId, 1);
    expect(answers.single.isEndOfStream, isTrue);

    await p.peer.close();
    await p.server.close();
  });

  test('GUARD: the reserved connection stream is never answered', () async {
    // Stream 0 carries connection-level flow control and is never a call, so a
    // call-scoped trailer there would be a frame on a reserved id. Harmless to
    // a peer of this implementation (measured: it materialises no state) but
    // still wrong on the wire.
    final p = _pair(
      const RpcSecurityPolicy(
        maxHeaders: 4,
        maxHeaderValueBytes: 16,
        closeOnProtocolError: false,
      ),
    );
    final answers = <RpcTransportMessage>[];
    p.peer.incoming.listen((m) {
      if (m.metadata?.getHeaderValue(RpcHeaders.grpcStatus) != null) {
        answers.add(m);
      }
    }, onError: (Object _) {});
    p.server.incomingMessages.listen((_) {}, onError: (Object _) {});

    await p.peer.send(
      RpcTransportMessage.withMetadata(metadata: _hostile(), streamId: 0),
    );
    await _settle();

    expect(answers, isEmpty);

    await p.peer.close();
    await p.server.close();
  });

  test('GUARD: a CLIENT does not answer with a status', () async {
    // The status belongs to a responder. A client refusing a server's metadata
    // reports it to its own caller and has nothing to send back.
    final policy = const RpcSecurityPolicy(
      maxHeaders: 4,
      maxHeaderValueBytes: 16,
      closeOnProtocolError: false,
    );
    final (peerChannel, clientChannel) = RpcFrameMultiplexedChannel.pair(
      policy: policy,
    );
    final client = RpcChannelTransport(
      channel: clientChannel,
      isClient: true,
      policy: policy,
    );
    final answers = <RpcTransportMessage>[];
    peerChannel.incoming
        .where((m) => m.streamId != 0)
        .listen(answers.add, onError: (Object _) {});
    client.incomingMessages.listen((_) {}, onError: (Object _) {});

    await peerChannel.send(
      RpcTransportMessage.withMetadata(metadata: _hostile(), streamId: 2),
    );
    await _settle();

    expect(answers, isEmpty);

    await peerChannel.close();
    await client.close();
  });

  test('conforming metadata still passes untouched', () async {
    final p = _pair(const RpcSecurityPolicy());
    final delivered = <RpcTransportMessage>[];
    final errors = <Object>[];
    p.server.incomingMessages.listen(delivered.add, onError: errors.add);

    await p.peer.send(
      RpcTransportMessage.withMetadata(
        metadata: RpcMetadata.forClientRequest('Svc', 'method'),
        streamId: 1,
      ),
    );
    await _settle();

    expect(errors, isEmpty);
    expect(delivered, hasLength(1));
    expect(delivered.single.methodPath, '/Svc/method');

    await p.peer.close();
    await p.server.close();
  });
}
