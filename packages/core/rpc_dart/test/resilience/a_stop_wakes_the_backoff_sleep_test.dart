// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// dispose() and disconnect() end the connect loop's backoff sleep, not only
// the attempts around it. A sleep they cannot reach keeps a timer pending, so
// the isolate stays alive for the rest of the delay after dispose(), and a
// connect() after disconnect() finds the old loop still asleep and waits it
// out.

import 'dart:async';

import 'package:rpc_dart/transport.dart';
import 'package:test/test.dart';

Future<bool> _within(Future<void> f, Duration within) => Future.any([
  f.then((_) => true),
  Future<bool>.delayed(within, () => false),
]);

void main() {
  test('connect after a disconnect mid-backoff does not wait it out', () async {
    var calls = 0;
    final connection = RpcClientConnection(
      backoff: const ExponentialBackoff(
        baseDelay: Duration(seconds: 5),
        jitter: false,
      ),
      transportFactory: (_) async {
        if (++calls == 1) throw Exception('refused');
        final (client, _) = RpcChannelTransport.memoryPair();
        return client;
      },
    );
    addTearDown(connection.dispose);
    final sleeping = connection.state.firstWhere(
      (s) => s is RpcClientConnecting && s.attempt == 2,
    );
    final online = connection.state.firstWhere((s) => s is RpcClientOnline);

    connection.connect();
    await sleeping;
    await connection.disconnect();
    connection.connect();

    expect(
      await _within(online, const Duration(seconds: 1)),
      isTrue,
      reason:
          'the stopped loop slept out its 5 s backoff before connect() '
          'could start a new one',
    );
  });

  test('GUARD without a stop the backoff is still waited out', () async {
    var calls = 0;
    final attempts = <Stopwatch>[];
    final connection = RpcClientConnection(
      backoff: const ExponentialBackoff(
        baseDelay: Duration(milliseconds: 300),
        jitter: false,
      ),
      transportFactory: (_) async {
        attempts.add(Stopwatch()..start());
        if (++calls == 1) throw Exception('refused');
        final (client, _) = RpcChannelTransport.memoryPair();
        return client;
      },
    );
    addTearDown(connection.dispose);
    final online = connection.state.firstWhere((s) => s is RpcClientOnline);
    connection.connect();
    await online.timeout(const Duration(seconds: 5));
    expect(calls, 2);
    expect(
      attempts.first.elapsedMilliseconds - attempts.last.elapsedMilliseconds,
      greaterThanOrEqualTo(250),
    );
  });
}
