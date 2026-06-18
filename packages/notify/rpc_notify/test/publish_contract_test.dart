// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_notify/rpc_notify.dart';
import 'package:test/test.dart';

void main() {
  group('NotifyPublisher integration', () {
    late InMemoryNotifyServiceEnvironment env;

    setUp(() async {
      env = await NotifyServiceFactory.inMemory();
    });

    tearDown(() => env.dispose());

    test('publishClient.publish delivers to subscribers via RPC', () async {
      final received = <NotifyEvent>[];
      env.subscriber.subscribe('orders').listen(received.add);

      await Future<void>.delayed(const Duration(milliseconds: 50));

      await env.publisher.publish(
        topic: 'orders',
        payload: {'id': '99', 'status': 'shipped'},
      );

      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(received.length, 1);
      expect(received.first.topic, 'orders');
      expect(received.first.payload['id'], '99');
    });

    test('publishClient.publishTo delivers only to targeted client', () async {
      // Use the repository directly to subscribe two clients with known IDs.
      const clientA = 'test-client-a';
      const clientB = 'test-client-b';

      final eventsA = <NotifyEvent>[];
      final eventsB = <NotifyEvent>[];

      env.repository.subscribe(clientA, 'chat').listen(eventsA.add);
      env.repository.subscribe(clientB, 'chat').listen(eventsB.add);

      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Targeted — only clientA should receive this.
      await env.publisher.publishTo(
        clientId: clientA,
        topic: 'chat',
        payload: {'msg': 'direct'},
      );

      // Broadcast — both clients should receive this.
      await env.publisher.publish(topic: 'chat', payload: {'msg': 'broadcast'});

      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(eventsA.length, 2);
      expect(eventsA[0].payload['msg'], 'direct');
      expect(eventsA[1].payload['msg'], 'broadcast');

      // clientB only gets the broadcast, not the targeted event.
      expect(eventsB.length, 1);
      expect(eventsB[0].payload['msg'], 'broadcast');
    });

    test('direct server.publish and publishClient.publish both work', () async {
      final received = <NotifyEvent>[];
      env.subscriber.subscribe('alerts').listen(received.add);

      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Direct (no RPC round-trip).
      env.server.publish(topic: 'alerts', payload: {'src': 'direct'});

      // Via RPC publish contract.
      await env.publisher.publish(topic: 'alerts', payload: {'src': 'rpc'});

      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(received.length, 2);
      expect(received[0].payload['src'], 'direct');
      expect(received[1].payload['src'], 'rpc');
    });
  });
}
