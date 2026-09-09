// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Every transport retains inbound frames until its first listener
// (BufferedBroadcastController), and `_ReconnectingTransportProxy.attach()` IS
// that first listener. It used to forward into a plain broadcast controller, so
// the inner buffer was drained into a controller nobody was listening to yet and
// everything the peer had sent was discarded one hop later.
//
// Measured through an in-memory pair, the peer greeting before the app
// subscribes:
//
//   late, through RpcClientConnection   0 frames
//   early, through RpcClientConnection  1 frame     <- same proxy, listener first
//   late, straight off the transport    1 frame     <- same lateness, no proxy
//
// The frame that always occupies that slot on a real connection is the
// connection-window advertisement, and losing it leaves the client's credit null
// -- which reads as "the peer does not participate in flow control", so sends
// stay unbounded for the life of the connection.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

/// A client transport with a frame already sitting in its inbound buffer.
Future<IRpcTransport> _clientWithAGreetingPending() async {
  final (clientChannel, serverChannel) = RpcFrameMultiplexedChannel.pair();
  final client = RpcChannelTransport(channel: clientChannel, isClient: true);
  final server = RpcChannelTransport(channel: serverChannel, isClient: false);

  await server.sendMetadata(
    7,
    RpcMetadata.forClientRequest('Greeter', 'hello'),
  );
  // Let it settle into the client's buffer. Without the wait the frame is still
  // in flight when the proxy attaches and every ordering passes.
  await Future<void>.delayed(const Duration(milliseconds: 50));
  return client;
}

void main() {
  test(
    'a frame that arrived before the app subscribed survives the proxy',
    () async {
      final client = await _clientWithAGreetingPending();
      final conn = RpcClientConnection(transportFactory: () async => client);

      conn.connect();
      // The documented way to wait for a usable connection -- and the ordering
      // that loses the frame: by the time this returns, attach() has already
      // drained the inner transport's buffer.
      await conn.state.firstWhere((s) => s is RpcClientOnline);

      final seen = <RpcTransportMessage>[];
      final sub = conn.transport.incomingMessages.listen(seen.add);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await sub.cancel();
      await conn.dispose();

      expect(
        seen,
        isNotEmpty,
        reason:
            'the peer greeted before the app subscribed; the proxy dropped it',
      );
    },
  );

  test('subscribing before connect() sees it too (the guard)', () async {
    final client = await _clientWithAGreetingPending();
    final conn = RpcClientConnection(transportFactory: () async => client);

    final seen = <RpcTransportMessage>[];
    final sub = conn.transport.incomingMessages.listen(seen.add);

    conn.connect();
    await conn.state.firstWhere((s) => s is RpcClientOnline);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await sub.cancel();
    await conn.dispose();

    expect(seen, isNotEmpty);
  });
}
