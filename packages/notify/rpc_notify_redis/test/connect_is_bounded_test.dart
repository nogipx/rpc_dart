// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Every network wait in this repository is bounded, and each unbounded one
// has cost an outage.
//
// The PING was the first. This is the second: a connect that hangs strands
// `_reconnecting`, and because that latch gates BOTH the reconnect and the
// health check, the repository then holds no connection, retries nothing, and
// says nothing. Publishes go nowhere for the life of the process.
//
// A `finally` does not help — it waits for a body that never finishes, which
// is exactly why the earlier fix for the same latch was not enough. Observed
// in production: both replicas serving writes with `_pubCmd == null`, no
// reconnect attempts logged, and zero Redis subscribers.

import 'package:rpc_notify_redis/rpc_notify_redis.dart';
import 'package:test/test.dart';

void main() {
  test(
    'a connect that would hang forever fails instead',
    () async {
      // Non-routable by RFC 5735: the TCP handshake neither completes nor is
      // refused. A bare Socket.connect waits on this indefinitely.
      final sw = Stopwatch()..start();
      await expectLater(
        RedisNotifyRepository.connect(host: '10.255.255.1', port: 6379),
        throwsA(anything),
      );
      sw.stop();

      expect(
        sw.elapsed,
        lessThan(const Duration(seconds: 25)),
        reason:
            'the connect must give up on its own. Unbounded, it strands '
            'the reconnect latch and the repository never speaks again',
      );
    },
    timeout: const Timeout(Duration(seconds: 40)),
  );
}
