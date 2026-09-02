// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:redis/redis.dart';
import 'package:rpc_notify_redis/rpc_notify_redis.dart';
import 'package:test/test.dart';

const _host = 'localhost';
const _port = 6379;

Future<RedisNotifyRepository> _connect({
  Duration healthCheckInterval = const Duration(seconds: 10),
}) {
  return RedisNotifyRepository.connect(
    host: _host,
    port: _port,
    healthCheckInterval: healthCheckInterval,
  );
}

void main() {
  group('RedisNotifyRepository', () {
    late RedisNotifyRepository repo;

    setUp(() async {
      repo = await _connect(
        healthCheckInterval: const Duration(milliseconds: 200),
      );
    });

    tearDown(() => repo.dispose());

    test('publish broadcasts to all subscribers of the topic', () async {
      final events1 = <String>[];
      final events2 = <String>[];

      repo
          .subscribe('client-1', 'orders')
          .listen((e) => events1.add(e.payload['id'] as String));
      repo
          .subscribe('client-2', 'orders')
          .listen((e) => events2.add(e.payload['id'] as String));

      await Future<void>.delayed(const Duration(milliseconds: 50));

      repo.publish('orders', {'id': 'a'});
      repo.publish('orders', {'id': 'b'});

      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(events1, ['a', 'b']);
      expect(events2, ['a', 'b']);
    });

    test('publish does not cross-contaminate topics', () async {
      final ordersEvents = <String>[];
      final chatEvents = <String>[];

      repo
          .subscribe('client-1', 'orders')
          .listen((e) => ordersEvents.add(e.topic));
      repo.subscribe('client-2', 'chat').listen((e) => chatEvents.add(e.topic));

      await Future<void>.delayed(const Duration(milliseconds: 50));

      repo.publish('orders', {'x': 1});
      repo.publish('chat', {'x': 2});

      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(ordersEvents, ['orders']);
      expect(chatEvents, ['chat']);
    });

    test('publishTo delivers only to the targeted client', () async {
      final events1 = <String>[];
      final events2 = <String>[];

      repo
          .subscribe('client-1', 'orders')
          .listen((e) => events1.add(e.payload['msg'] as String));
      repo
          .subscribe('client-2', 'orders')
          .listen((e) => events2.add(e.payload['msg'] as String));

      await Future<void>.delayed(const Duration(milliseconds: 50));

      repo.publishTo('client-1', 'orders', {'msg': 'hello'});

      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(events1, ['hello']);
      expect(events2, isEmpty);
    });

    test('unsubscribe stops delivery to that client', () async {
      final events = <String>[];

      repo
          .subscribe('client-1', 'news')
          .listen((e) => events.add(e.payload['v'] as String));

      await Future<void>.delayed(const Duration(milliseconds: 50));

      repo.publish('news', {'v': 'before'});
      await Future<void>.delayed(const Duration(milliseconds: 200));

      repo.unsubscribe('client-1', 'news');
      repo.publish('news', {'v': 'after'});
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(events, ['before']);
    });

    test('subscriberCount reflects active subscriptions', () {
      expect(repo.subscriberCount('orders'), 0);

      repo.subscribe('client-1', 'orders');
      expect(repo.subscriberCount('orders'), 1);

      repo.subscribe('client-2', 'orders');
      expect(repo.subscriberCount('orders'), 2);

      repo.unsubscribe('client-1', 'orders');
      expect(repo.subscriberCount('orders'), 1);
    });

    test('activeTopics returns topics with subscribers', () {
      expect(repo.activeTopics(), isEmpty);

      repo.subscribe('client-1', 'orders');
      repo.subscribe('client-2', 'chat');

      expect(repo.activeTopics(), containsAll(['orders', 'chat']));

      repo.unsubscribe('client-1', 'orders');
      repo.unsubscribe('client-2', 'orders');

      expect(repo.activeTopics(), isNot(contains('orders')));
    });

    test(
      'cross-instance: publish on one repo delivers to subscriber on another',
      () async {
        final repo2 = await _connect();

        final received = <String>[];
        try {
          repo2
              .subscribe('client-x', 'vault-sync')
              .listen((e) => received.add(e.payload['op'] as String));

          await Future<void>.delayed(const Duration(milliseconds: 50));

          // repo publishes, repo2 receives — simulates two server replicas.
          repo.publish('vault-sync', {'op': 'pull'});

          await Future<void>.delayed(const Duration(milliseconds: 200));

          expect(received, ['pull']);
        } finally {
          await repo2.dispose();
        }
      },
    );

    test(
      'cross-instance: publishTo delivers only to matching client on another',
      () async {
        final repo2 = await _connect();

        final receivedX = <String>[];
        final receivedY = <String>[];
        try {
          repo2
              .subscribe('client-x', 'vault-sync')
              .listen((e) => receivedX.add(e.payload['op'] as String));
          repo2
              .subscribe('client-y', 'vault-sync')
              .listen((e) => receivedY.add(e.payload['op'] as String));

          await Future<void>.delayed(const Duration(milliseconds: 50));

          repo.publishTo('client-x', 'vault-sync', {'op': 'pull'});

          await Future<void>.delayed(const Duration(milliseconds: 200));

          expect(receivedX, ['pull']);
          expect(receivedY, isEmpty);
        } finally {
          await repo2.dispose();
        }
      },
    );

    test(
      'reconnects after connection drop and re-delivers events',
      () async {
        const topic = 'reconnect-test';
        final received = <String>[];

        repo
            .subscribe('client-1', topic)
            .listen((e) => received.add(e.payload['v'] as String));
        await Future<void>.delayed(const Duration(milliseconds: 50));

        // Kill the repo's subscriber connection (it is in pubsub mode) from a
        // separate admin connection to simulate a Redis connection drop.
        final admin = await RedisConnection().connect(_host, _port);
        try {
          await admin.send_object(['CLIENT', 'KILL', 'TYPE', 'pubsub']);
        } finally {
          await admin.get_connection().close();
        }

        // Wait for reconnect: onDone is immediate, then the first backoff (1s).
        await Future<void>.delayed(const Duration(milliseconds: 1500));

        // Publish from a fresh repo — the reconnected repo should receive it.
        final publisher = await _connect();
        try {
          publisher.publish(topic, {'v': 'after-reconnect'});
          await Future<void>.delayed(const Duration(milliseconds: 300));
          expect(received, ['after-reconnect']);
        } finally {
          await publisher.dispose();
        }
      },
      timeout: const Timeout(Duration(seconds: 10)),
    );

    test(
      'recovers from a SECOND drop, so the reconnect latch is never stranded',
      () async {
        // Repeated recovery, which one drop does not show.
        //
        // Honest about what this does NOT cover: the stranding that took a
        // managed deployment down for 22 hours needed `_closeConnections` to
        // throw synchronously, and that path is now unreachable — the close is
        // guarded, and the latch is released in a `finally` besides. So this
        // test passes against the broken version too. It is here because
        // recovering twice is worth pinning, not because it guards that bug;
        // guarding it would need a seam whose only purpose is to re-open the
        // hole the fix closed.
        const topic = 'reconnect-twice';
        final received = <String>[];

        repo
            .subscribe('client-1', topic)
            .listen((e) => received.add(e.payload['v'] as String));
        await Future<void>.delayed(const Duration(milliseconds: 50));

        Future<void> killPubsub() async {
          final admin = await RedisConnection().connect(_host, _port);
          try {
            await admin.send_object(['CLIENT', 'KILL', 'TYPE', 'pubsub']);
          } finally {
            await admin.get_connection().close();
          }
          // onDone is immediate, then the first backoff (1s).
          await Future<void>.delayed(const Duration(milliseconds: 1500));
        }

        await killPubsub();
        await killPubsub();

        final publisher = await _connect();
        try {
          publisher.publish(topic, {'v': 'after-two-drops'});
          await Future<void>.delayed(const Duration(milliseconds: 300));
          expect(
            received,
            ['after-two-drops'],
            reason:
                'a latch released only on the happy path leaves the '
                'repository dead from the second drop onward',
          );
        } finally {
          await publisher.dispose();
        }
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );
  });
}
