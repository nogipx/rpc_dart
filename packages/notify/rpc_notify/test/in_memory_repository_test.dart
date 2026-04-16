// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_notify/rpc_notify.dart';
import 'package:test/test.dart';

void main() {
  group('InMemoryNotifyRepository', () {
    late InMemoryNotifyRepository repo;

    setUp(() => repo = InMemoryNotifyRepository());
    tearDown(() => repo.dispose());

    test('publish broadcasts to all subscribers of the topic', () async {
      final events1 = <NotifyEvent>[];
      final events2 = <NotifyEvent>[];

      repo.subscribe('client-1', 'orders').listen(events1.add);
      repo.subscribe('client-2', 'orders').listen(events2.add);

      repo.publish('orders', {'id': '1'});
      repo.publish('orders', {'id': '2'});

      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(events1.length, 2);
      expect(events2.length, 2);
      expect(events1.first.payload['id'], '1');
    });

    test('publish does not cross-contaminate topics', () async {
      final ordersEvents = <NotifyEvent>[];
      final chatEvents = <NotifyEvent>[];

      repo.subscribe('client-1', 'orders').listen(ordersEvents.add);
      repo.subscribe('client-2', 'chat').listen(chatEvents.add);

      repo.publish('orders', {'order': 'x'});
      repo.publish('chat', {'msg': 'hello'});

      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(ordersEvents.length, 1);
      expect(ordersEvents.first.topic, 'orders');
      expect(chatEvents.length, 1);
      expect(chatEvents.first.topic, 'chat');
    });

    test('publishTo delivers only to the targeted client', () async {
      final events1 = <NotifyEvent>[];
      final events2 = <NotifyEvent>[];

      repo.subscribe('client-1', 'orders').listen(events1.add);
      repo.subscribe('client-2', 'orders').listen(events2.add);

      repo.publishTo('client-1', 'orders', {'targeted': true});

      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(events1.length, 1);
      expect(events2.length, 0);
    });

    test('subscriberCount reflects active subscriptions', () {
      expect(repo.subscriberCount('orders'), 0);

      repo.subscribe('client-1', 'orders');
      expect(repo.subscriberCount('orders'), 1);

      repo.subscribe('client-2', 'orders');
      expect(repo.subscriberCount('orders'), 2);
    });

    test('activeTopics returns topics with subscribers', () {
      expect(repo.activeTopics(), isEmpty);

      repo.subscribe('client-1', 'orders');
      repo.subscribe('client-2', 'chat');

      final topics = repo.activeTopics();
      expect(topics, containsAll(['orders', 'chat']));
    });
  });
}
