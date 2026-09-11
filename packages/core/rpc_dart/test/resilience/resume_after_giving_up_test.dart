// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A recovery API that works exactly once is RPC-19's give-away, and the one
// place `RpcClientConnection` could have it is after `maxAttempts` runs out.
//
// Giving up is a RECOVERABLE failure: `connect()` is documented to resume, and
// the loop's exit resets the attempt counter by way of connect() rather than by
// writing a lifecycle flag. Writing `_isStopped` there instead -- which is
// exactly what `RpcHttp2CallerTransport` did with `_isClosed`, fixed at
// 63aa8e93 -- would leave the object telling you to reconnect and refusing.
//
// `stops after maxAttempts exceeded` covers the giving up. It never calls
// connect() again, so it cannot see the difference: measured with
// `_isStopped = true` added to the give-up path, that test and the other 118 in
// test/resilience stay green and only this one goes red.
@TestOn('vm')
library;

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

/// Polls until [connection] reports [T], or gives up. Returns whether it did.
Future<bool> _reaches<T extends RpcClientConnectionState>(
  RpcClientConnection connection,
  Duration budget,
) async {
  final deadline = DateTime.now().add(budget);
  while (DateTime.now().isBefore(deadline)) {
    if (connection.currentState is T) return true;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  return connection.currentState is T;
}

void main() {
  test('connect() resumes after maxAttempts ran out', () async {
    var peerUp = false;
    var calls = 0;
    final made = <IRpcTransport>[];

    final connection = RpcClientConnection(
      transportFactory: () async {
        calls++;
        if (!peerUp) throw StateError('peer is down');
        final (client, _) = RpcInMemoryTransport.pair();
        made.add(client);
        return client;
      },
      backoff: const FixedBackoff(Duration(milliseconds: 10)),
      maxAttempts: 3,
    );
    addTearDown(() async {
      await connection.dispose();
      for (final t in made) {
        await t.close();
      }
    });

    connection.connect();
    expect(
      await _reaches<RpcClientDisconnected>(
        connection,
        const Duration(seconds: 2),
      ),
      isTrue,
      reason: 'the loop never gave up, so there is nothing to resume from',
    );
    expect(calls, 3);

    // The peer comes back and the caller retries, which is the whole point of
    // maxAttempts being a budget rather than a death sentence.
    peerUp = true;
    connection.connect();
    expect(
      await _reaches<RpcClientOnline>(connection, const Duration(seconds: 3)),
      isTrue,
      reason:
          'giving up was recorded as terminal: connect() is documented to '
          'resume and the connection refused',
    );

    // Twice, because once proves nothing about a recovery API.
    await connection.disconnect();
    expect(
      await _reaches<RpcClientIdle>(connection, const Duration(seconds: 2)),
      isTrue,
    );
    connection.connect();
    expect(
      await _reaches<RpcClientOnline>(connection, const Duration(seconds: 3)),
      isTrue,
      reason: 'the second resume did not come back',
    );
  });

  test('GUARD: giving up still stops, and does not keep dialling', () async {
    // Without this, "resume works" would also pass on a loop that never
    // honoured maxAttempts at all.
    var calls = 0;
    final connection = RpcClientConnection(
      transportFactory: () async {
        calls++;
        throw StateError('peer is down');
      },
      backoff: const FixedBackoff(Duration(milliseconds: 10)),
      maxAttempts: 3,
    );
    addTearDown(connection.dispose);

    connection.connect();
    expect(
      await _reaches<RpcClientDisconnected>(
        connection,
        const Duration(seconds: 2),
      ),
      isTrue,
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(calls, 3, reason: 'the loop kept dialling past its budget');
  });
}
