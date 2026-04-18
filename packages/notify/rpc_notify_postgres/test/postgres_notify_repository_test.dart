// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:postgres/postgres.dart';
import 'package:rpc_notify_postgres/rpc_notify_postgres.dart';
import 'package:test/test.dart';

final _endpoint = Endpoint(
  host: 'localhost',
  port: 5433,
  database: 'postgres',
  username: 'postgres',
  password: 'postgres',
);

const _settings = ConnectionSettings(sslMode: SslMode.disable);

void main() {
  group('PostgresNotifyRepository', () {
    late PostgresNotifyRepository repo;

    setUp(() async {
      repo = await PostgresNotifyRepository.connect(
        endpoint: _endpoint,
        settings: _settings,
        healthCheckInterval: const Duration(milliseconds: 200),
      );
    });

    tearDown(() => repo.dispose());

    test('publish broadcasts to all subscribers of the topic', () async {
      final events1 = <String>[];
      final events2 = <String>[];

      repo.subscribe('client-1', 'orders').listen((e) => events1.add(e.payload['id'] as String));
      repo.subscribe('client-2', 'orders').listen((e) => events2.add(e.payload['id'] as String));

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

      repo.subscribe('client-1', 'orders').listen((e) => ordersEvents.add(e.topic));
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

      repo.subscribe('client-1', 'orders').listen((e) => events1.add(e.payload['msg'] as String));
      repo.subscribe('client-2', 'orders').listen((e) => events2.add(e.payload['msg'] as String));

      await Future<void>.delayed(const Duration(milliseconds: 50));

      repo.publishTo('client-1', 'orders', {'msg': 'hello'});

      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(events1, ['hello']);
      expect(events2, isEmpty);
    });

    test('unsubscribe stops delivery to that client', () async {
      final events = <String>[];

      repo.subscribe('client-1', 'news').listen((e) => events.add(e.payload['v'] as String));

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

    test('cross-instance: publish on one repo delivers to subscriber on another', () async {
      final repo2 = await PostgresNotifyRepository.connect(
        endpoint: _endpoint,
        settings: _settings,
      );

      final received = <String>[];
      try {
        repo2.subscribe('client-x', 'vault-sync').listen((e) => received.add(e.payload['op'] as String));

        await Future<void>.delayed(const Duration(milliseconds: 50));

        // repo publishes, repo2 receives — simulates two server replicas
        repo.publish('vault-sync', {'op': 'pull'});

        await Future<void>.delayed(const Duration(milliseconds: 200));

        expect(received, ['pull']);
      } finally {
        await repo2.dispose();
      }
    });

    test('cross-instance: publishTo on one repo delivers only to matching client on another', () async {
      final repo2 = await PostgresNotifyRepository.connect(
        endpoint: _endpoint,
        settings: _settings,
      );

      final receivedX = <String>[];
      final receivedY = <String>[];
      try {
        repo2.subscribe('client-x', 'vault-sync').listen((e) => receivedX.add(e.payload['op'] as String));
        repo2.subscribe('client-y', 'vault-sync').listen((e) => receivedY.add(e.payload['op'] as String));

        await Future<void>.delayed(const Duration(milliseconds: 50));

        repo.publishTo('client-x', 'vault-sync', {'op': 'pull'});

        await Future<void>.delayed(const Duration(milliseconds: 200));

        expect(receivedX, ['pull']);
        expect(receivedY, isEmpty);
      } finally {
        await repo2.dispose();
      }
    });

    test('reconnects after connection drop and re-delivers events', () async {
      const topic = 'reconnect-test';
      final received = <String>[];

      repo.subscribe('client-1', topic).listen((e) => received.add(e.payload['v'] as String));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Open a separate admin connection and kill all other idle connections
      // to simulate a postgres connection drop.
      final admin = await Connection.open(_endpoint, settings: _settings);
      try {
        await admin.execute(
          "SELECT pg_terminate_backend(pid) FROM pg_stat_activity "
          "WHERE datname = current_database() "
          "AND pid != pg_backend_pid() "
          "AND state = 'idle'",
        );
      } finally {
        await admin.close();
      }

      // Wait for: health check (200ms) + reconnect delay (1s) + connection time.
      await Future<void>.delayed(const Duration(milliseconds: 1500));

      // Publish from a fresh repo — the reconnected repo should receive it.
      final publisher = await PostgresNotifyRepository.connect(
        endpoint: _endpoint,
        settings: _settings,
      );
      try {
        publisher.publish(topic, {'v': 'after-reconnect'});
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(received, ['after-reconnect']);
      } finally {
        await publisher.dispose();
      }
    }, timeout: const Timeout(Duration(seconds: 10)));
  });
}
