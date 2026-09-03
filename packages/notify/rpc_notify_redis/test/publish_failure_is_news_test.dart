// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A publish that reaches nobody is the user-visible fault, so it must not be
// the quiet one.
//
// Both halves of this path were silent, and together they let a replica serve
// writes while fanning out none of them. One was observed doing exactly that:
// accepting putStates for minutes with no Redis connection at all, every
// publish returning at the null check, nothing anywhere saying so, and the
// operator seeing only "notifications stopped working".
//
//  * no connection was a bare `return`
//  * the send's result was `.ignore()`d, so a write onto a dead socket was
//    discarded too — leaving the periodic PING as the only thing that could
//    notice, when the traffic itself is both more frequent and more relevant.

import 'package:rpc_notify_redis/rpc_notify_redis.dart';
import 'package:test/test.dart';

void main() {
  test('publishing after dispose is reported, not swallowed', () async {
    final logs = <String>[];
    final repo = await RedisNotifyRepository.connect(
      host: 'localhost',
      keyPrefix: 'test_publish_news:',
      onLog: logs.add,
    );

    // Disposing drops the connections, which is the same state a replica is in
    // when its connection died: cmd is gone and every publish is a no-op.
    await repo.dispose();
    logs.clear();

    repo.publish('some-topic', {'a': 1});

    expect(
      logs,
      isNotEmpty,
      reason:
          'a publish that goes nowhere is exactly what the user feels; '
          'silence here is how a half-dead fanout stays invisible',
    );
    expect(logs.first, contains('went nowhere'));
  });

  test('the complaint is rate limited', () async {
    // A broken replica publishes constantly. One line per event would bury the
    // log this exists to make readable.
    final logs = <String>[];
    final repo = await RedisNotifyRepository.connect(
      host: 'localhost',
      keyPrefix: 'test_publish_news2:',
      onLog: logs.add,
    );
    await repo.dispose();
    logs.clear();

    for (var i = 0; i < 50; i++) {
      repo.publish('t', {'i': i});
    }

    expect(
      logs.length,
      1,
      reason: 'fifty failed publishes are one fault, not fifty',
    );
  });
}
