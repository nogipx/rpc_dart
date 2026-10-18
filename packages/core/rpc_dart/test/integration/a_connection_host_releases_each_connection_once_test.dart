// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// RpcConnectionHost: one endpoint per connection of the mode's kind, released
// once whichever path ends it, and a cap that refuses past its limit.

import 'dart:async';

import 'package:rpc_dart/transport.dart';
import 'package:test/test.dart';

void main() {
  test('the mode decides the endpoint kind', () async {
    final responders = RpcConnectionHost(mode: RpcResponderMode((_) {}));
    final peers = RpcConnectionHost(mode: RpcPeerMode((_) {}));
    final (_, a) = RpcChannelTransport.memoryPair();
    final (_, b) = RpcChannelTransport.memoryPair();

    expect(
      responders.serve(a, done: Completer<void>().future),
      isA<RpcResponderEndpoint>(),
    );
    expect(
      peers.serve(b, done: Completer<void>().future),
      isA<RpcPeerEndpoint>(),
    );
    expect(responders.responders, hasLength(1));
    expect(peers.responders, isEmpty);
    expect(peers.length, 1);

    await responders.stop();
    await peers.stop();
  });

  test('done, release and stop release a connection once', () async {
    final host = RpcConnectionHost(mode: RpcResponderMode((_) {}));
    var released = 0;
    final done = Completer<void>();
    final (_, transport) = RpcChannelTransport.memoryPair();
    final endpoint = host.serve(
      transport,
      done: done.future,
      onRelease: () => released++,
    );

    host.release(endpoint);
    done.complete();
    await Future<void>.delayed(Duration.zero);
    await host.stop();

    expect(released, 1);
    expect(host.length, 0);
  });

  test('stop releases what is still live', () async {
    final host = RpcConnectionHost(mode: RpcResponderMode((_) {}));
    var released = 0;
    for (var i = 0; i < 3; i++) {
      final (_, transport) = RpcChannelTransport.memoryPair();
      host.serve(
        transport,
        done: Completer<void>().future,
        onRelease: () => released++,
      );
    }

    await host.stop();

    expect(released, 3);
    expect(host.length, 0);
  });

  test('a register that throws releases the endpoint and rethrows', () async {
    final host = RpcConnectionHost(
      mode: RpcResponderMode((_) => throw StateError('bad contract')),
    );
    var released = 0;
    final (_, transport) = RpcChannelTransport.memoryPair();

    expect(
      () => host.serve(
        transport,
        done: Completer<void>().future,
        onRelease: () => released++,
      ),
      throwsStateError,
    );
    expect(released, 1);
    expect(host.length, 0);
  });

  test('admit refuses at the cap, counting pending handshakes', () async {
    final host = RpcConnectionHost(
      mode: RpcResponderMode((_) {}),
      maxConnections: 2,
    );
    final (_, transport) = RpcChannelTransport.memoryPair();
    host.serve(transport, done: Completer<void>().future);

    expect(host.admit(), isTrue);
    expect(host.admit(pending: 1), isFalse);

    await host.stop();
    expect(host.admit(pending: 1), isTrue);
  });
}
