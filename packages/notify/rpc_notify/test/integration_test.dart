// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_notify/rpc_notify.dart';
import 'package:test/test.dart';

void main() {
  group('NotifyServiceFactory.inMemory integration', () {
    late InMemoryNotifyServiceEnvironment env;

    setUp(() async {
      env = await NotifyServiceFactory.inMemory();
    });

    tearDown(() => env.dispose());

    test('subscribe and publish delivers events to client', () async {
      final received = <NotifyEvent>[];
      final sub = env.subscriber.subscribe('orders').listen(received.add);

      // Small delay to allow the RPC stream to establish
      await Future<void>.delayed(const Duration(milliseconds: 50));

      env.server.publish(topic: 'orders', payload: {'id': '42'});
      env.server.publish(topic: 'orders', payload: {'id': '43'});

      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(received.length, 2);
      expect(received[0].topic, 'orders');
      expect(received[0].payload['id'], '42');
      expect(received[1].payload['id'], '43');

      await sub.cancel();
    });

    test(
      'two clients subscribed to different topics — no cross-contamination',
      () async {
        final ordersEvents = <NotifyEvent>[];
        final chatEvents = <NotifyEvent>[];

        env.subscriber.subscribe('orders').listen(ordersEvents.add);
        env.subscriber.subscribe('chat').listen(chatEvents.add);

        await Future<void>.delayed(const Duration(milliseconds: 50));

        env.server.publish(topic: 'orders', payload: {'x': 1});
        env.server.publish(topic: 'chat', payload: {'msg': 'hi'});

        await Future<void>.delayed(const Duration(milliseconds: 100));

        expect(ordersEvents.length, 1);
        expect(chatEvents.length, 1);
        expect(ordersEvents.first.topic, 'orders');
        expect(chatEvents.first.topic, 'chat');
      },
    );

    test('unsubscribe stops delivery', () async {
      final received = <NotifyEvent>[];
      env.subscriber.subscribe('orders').listen(received.add);

      await Future<void>.delayed(const Duration(milliseconds: 50));
      env.server.publish(topic: 'orders', payload: {'n': 1});
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await env.subscriber.unsubscribe('orders');

      env.server.publish(topic: 'orders', payload: {'n': 2});
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(received.length, 1);
    });

    test('activeTopics reflects current subscriptions', () async {
      expect(env.subscriber.activeTopics, isEmpty);

      env.subscriber.subscribe('orders');
      env.subscriber.subscribe('chat');

      expect(env.subscriber.activeTopics, containsAll(['orders', 'chat']));

      await env.subscriber.unsubscribe('orders');
      expect(env.subscriber.activeTopics, ['chat']);
    });
  });
}
