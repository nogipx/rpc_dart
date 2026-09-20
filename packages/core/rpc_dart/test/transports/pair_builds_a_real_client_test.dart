// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A defect in the WITNESS, which is the class with the least defence.
//
// `RpcFrameMultiplexedChannel` picks its oversized-frame policy by side, and
// the choice is argued: a SERVER closes, because dart:io has buffered the whole
// message before this class sees a byte and a surviving connection lets the
// peer repeat that peak; a CLIENT must not, because killing the connection over
// one large response takes every other in-flight call with it, and
// RESOURCE_EXHAUSTED on that one RPC is gRPC's answer.
//
// `pair()` made no such choice. Both halves took the constructor default --
// which is the SERVER's -- so the frame-codec harness, the one path that
// exercises the real encoder and decoder, handed every suite a "client" that
// would kill its connection. A change breaking the client's "fail the stream,
// keep the connection" behaviour would have passed.
//
// What the flag DOES is witnessed by oversized_frame_is_per_call_test, which
// builds its channel by hand and passes `closeOnOversizedFrame: false`
// explicitly -- and that is exactly why this went unnoticed: the behaviour was
// covered through a channel nobody builds that way in production, while the
// factory everything else uses set it the other way.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

/// A byte channel that carries nothing: the GUARD only reads a flag.
final class _NullChannel implements IRpcChannel {
  final _in = StreamController<Uint8List>();
  bool _closed = false;

  @override
  bool get isClosed => _closed;

  @override
  Stream<Uint8List> get incoming => _in.stream;

  @override
  Future<void> send(Uint8List data) async {}

  @override
  Future<void> close() async {
    _closed = true;
    if (!_in.isClosed) await _in.close();
  }
}

void main() {
  test('pair() gives the client half the CLIENT policy', () {
    final (client, server) = RpcFrameMultiplexedChannel.pair();

    expect(
      client.closeOnOversizedFrame,
      isFalse,
      reason:
          'a client fails the stream and keeps the connection; closing takes '
          'every other in-flight call down with it',
    );
    expect(
      server.closeOnOversizedFrame,
      isTrue,
      reason: 'a server closes: the peak is already resident',
    );

    client.close();
    server.close();
  });

  // CONTROL: the side-dependent choice at the other factory, which was already
  // right. If these two ever disagree again, this pair says so.
  test('CONTROL: fromChannel still chooses by side', () {
    final (client, server) = RpcChannelTransport.pair();

    expect(client.isClient, isTrue);
    expect(server.isClient, isFalse);

    client.close();
    server.close();
  });

  // GUARD: the default is the server's, and it stays that way. A caller that
  // builds the channel directly and says nothing is a server.
  test('GUARD: the bare constructor still defaults to the server policy', () {
    final bare = RpcFrameMultiplexedChannel(channel: _NullChannel());

    expect(bare.closeOnOversizedFrame, isTrue);

    bare.close();
  });
}
