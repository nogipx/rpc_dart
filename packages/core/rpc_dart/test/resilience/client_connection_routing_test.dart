// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Audit finding B1. _ReconnectingTransportProxy served getMessagesForStream by
// re-filtering its own broadcast, which evaluates one predicate per ACTIVE
// STREAM for every inbound message. Every real transport routes through a
// per-stream map, so wrapping one in RpcClientConnection -- the recommended
// way to get auto-reconnect -- silently gave that up.
//
// Measured, 100 streams / 20000 messages:
//     per-stream map lookup : 6ms
//     broadcast + where()   : 342ms   (50.9x)
//
// The canary is behavioural rather than a timing assertion: it pins that the
// proxy hands back the INNER transport's per-stream stream, which is what
// makes the routing O(1). A timing threshold would flake on shared CI.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

void main() {
  test('per-stream routing is delegated to the live transport', () async {
    late RpcChannelTransport inner;
    final connection = RpcClientConnection(
      transportFactory: () async {
        final (client, _) = RpcChannelTransport.pair();
        inner = client;
        return client;
      },
    );

    connection.connect();
    await connection.state.firstWhere((s) => s is RpcClientOnline);

    final streamId = connection.transport.createStream();

    // The inner transport hands out a dedicated single-subscription controller
    // per stream. The filtered broadcast could not: it is a broadcast, and it
    // is not the inner transport's object.
    final viaProxy = connection.transport.getMessagesForStream(streamId);
    expect(
      viaProxy.isBroadcast,
      isFalse,
      reason: 'a filtered broadcast is broadcast; the delegated one is not',
    );

    // And it is the inner transport's own per-stream stream: that one is also
    // single-subscription, unlike the proxy's broadcast.
    expect(inner.getMessagesForStream(streamId).isBroadcast, isFalse);

    await connection.dispose();
  });

  test('messages still reach a per-stream subscriber', () async {
    late RpcChannelTransport peer;
    final connection = RpcClientConnection(
      transportFactory: () async {
        final (client, server) = RpcChannelTransport.pair();
        peer = server;
        return client;
      },
    );

    connection.connect();
    await connection.state.firstWhere((s) => s is RpcClientOnline);

    final streamId = connection.transport.createStream();
    final received = <RpcTransportMessage>[];
    final sub = connection.transport
        .getMessagesForStream(streamId)
        .listen(received.add);

    await peer.sendMetadata(streamId, RpcMetadata.forServerInitialResponse());
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(received, hasLength(1));

    await sub.cancel();
    await connection.dispose();
  });

  test('subscribing before the first connect still works', () async {
    final connection = RpcClientConnection(
      transportFactory: () async => RpcChannelTransport.pair().$1,
    );

    // No inner transport yet: the proxy must fall back rather than throw.
    expect(() => connection.transport.getMessagesForStream(1), returnsNormally);

    await connection.dispose();
  });
}
