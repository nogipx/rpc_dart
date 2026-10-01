// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// `RpcDirectMultiplexedChannel` fed its `incoming` from a plain broadcast
// controller, started from the CONSTRUCTOR -- and a broadcast with no listener
// drops what it is given. The peer advertises its connection window from its own
// constructor, so building the two ends with anything awaited in between lost that
// grant:
//
//     pair(), one event-loop turn between the ends   server credit null
//     pair(), no gap                                 server credit 67108864
//     memoryPair()                                   server credit 67108864
//
// `memoryPair()` was safe by accident: it builds both ends in one expression, so
// nothing can interleave. The public `pair()` offers no such guarantee, and a
// transport with no connection credit has flow control off in that direction.
//
// Same defect already fixed in the isolate and wasm bridges.
@TestOn('vm')
library;

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

/// Builds both ends of a `pair()`, awaiting one event-loop turn in between when
/// [gap] is set, and returns the credit each side ended up with.
Future<(int?, int?)> _credits({required bool gap}) async {
  final (clientCh, serverCh) = RpcDirectMultiplexedChannel.pair();
  final client = RpcChannelTransport(
    channel: clientCh,
    isClient: true,
    policy: const RpcSecurityPolicy(),
  );
  if (gap) await Future<void>.delayed(Duration.zero);
  final server = RpcChannelTransport(
    channel: serverCh,
    isClient: false,
    policy: const RpcSecurityPolicy(),
  );
  addTearDown(() async {
    await client.close().catchError((Object _) {});
    await server.close().catchError((Object _) {});
  });

  // Let every constructor-time advertisement land.
  await Future<void>.delayed(const Duration(milliseconds: 200));
  return (
    client.flowControlConnectionCredit,
    server.flowControlConnectionCredit,
  );
}

void main() {
  // WITNESS. Before: (67108864, null).
  test('a grant sent before the other end subscribes is not lost', () async {
    final (clientCredit, serverCredit) = await _credits(gap: true);

    expect(
      clientCredit,
      isNotNull,
      reason: 'the arm needs both advertisements to have happened',
    );
    expect(
      serverCredit,
      isNotNull,
      reason:
          'the client advertises its window from its own constructor, and a '
          'side that never receives that grant has flow control off in that '
          'direction for the life of the connection',
    );
    expect(serverCredit, clientCredit);
  });

  // CONTROL. No gap, so nothing can arrive before a listener exists. It read
  // correctly before the fix too -- which is what says the witness above is about
  // the ORDER and not about the grant never being sent.
  test('CONTROL: with no gap both ends were always credited', () async {
    final (clientCredit, serverCredit) = await _credits(gap: false);

    expect(clientCredit, isNotNull);
    expect(serverCredit, clientCredit);
  });

  // CONTROL. The shipped convenience builds both ends in one expression and so was
  // never exposed. Here so a change to `memoryPair` cannot quietly reintroduce the
  // window.
  test('CONTROL: memoryPair credits both ends', () async {
    final (client, server) = RpcChannelTransport.memoryPair();
    addTearDown(() async {
      await client.close().catchError((Object _) {});
      await server.close().catchError((Object _) {});
    });
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(client.flowControlConnectionCredit, isNotNull);
    expect(
      server.flowControlConnectionCredit,
      client.flowControlConnectionCredit,
    );
  });
}
