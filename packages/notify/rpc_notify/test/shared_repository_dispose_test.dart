// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// One client disconnecting must not take the server's notify bus with it.
//
// A server registers its contracts PER CONNECTION while the notify repository
// is an application singleton shared by all of them, and rpc_dart disposes a
// connection's contracts when its endpoint closes. So a subscriber that
// disposed the repository it was handed ended the bus for the whole process on
// the FIRST disconnect: no Redis connection, no reconnect, no log line, and
// every other client's stream closed with it.
//
// These tests pin the ownership rule and both of the failure's tails.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_notify/rpc_notify.dart';
import 'package:test/test.dart';

/// Records whether the repository it stands in for was disposed.
class _SpyRepository implements INotifyRepository {
  int disposeCalls = 0;
  final unsubscribed = <String>[];

  @override
  Stream<NotifyEvent> subscribe(String clientId, String topic) =>
      const Stream<NotifyEvent>.empty();

  @override
  void unsubscribe(String clientId, String topic) => unsubscribed.add(topic);

  @override
  void publish(String topic, Map<String, dynamic> payload) {}

  @override
  void publishTo(String clientId, String topic, Map<String, dynamic> payload) {}

  @override
  List<String> activeTopics() => const [];

  @override
  int subscriberCount(String topic) => 0;

  @override
  Future<void> dispose() async => disposeCalls++;
}

/// A repository whose streams the bus can close underneath a subscriber —
/// a reconnect, a shutdown, an unsubscribe from the other side. Reuses a live
/// stream for a repeat client id and builds a new one once the old is closed,
/// which is what both real implementations do.
class _ClosableRepository implements INotifyRepository {
  final _controllers = <String, StreamController<NotifyEvent>>{};

  String _key(String clientId, String topic) => '$clientId|$topic';

  @override
  Stream<NotifyEvent> subscribe(String clientId, String topic) {
    final key = _key(clientId, topic);
    final existing = _controllers[key];
    if (existing != null && !existing.isClosed) return existing.stream;
    final controller = StreamController<NotifyEvent>.broadcast();
    _controllers[key] = controller;
    return controller.stream;
  }

  /// The bus closing its streams — not the subscriber asking it to.
  Future<void> closeAllStreams() async {
    for (final c in _controllers.values) {
      await c.close();
    }
  }

  void emit(String topic) {
    for (final entry in _controllers.entries) {
      if (entry.key.endsWith('|$topic') && !entry.value.isClosed) {
        entry.value.add(NotifyEvent(topic: topic, payload: const {}));
      }
    }
  }

  @override
  void unsubscribe(String clientId, String topic) {
    _controllers.remove(_key(clientId, topic))?.close();
  }

  @override
  void publish(String topic, Map<String, dynamic> payload) {}

  @override
  void publishTo(String clientId, String topic, Map<String, dynamic> payload) {}

  @override
  List<String> activeTopics() => const [];

  @override
  int subscriberCount(String topic) => 0;

  @override
  Future<void> dispose() async => closeAllStreams();
}

/// One server-side connection: its own endpoint and its own per-connection
/// contract over the application-wide [repository]. This is the production
/// shape — a sync server's `buildContracts` builds exactly this per client.
///
/// No dataTransferMode: the default is what production uses. (The factory's
/// `transport is RpcInMemoryTransport` check can never be true — `pair()`
/// returns RpcChannelTransport — so zeroCopy is never actually selected, and
/// forcing it here fails the call outright.)
RpcResponderEndpoint _serveConnection(
  IRpcTransport transport,
  INotifyRepository repository,
  String label,
) {
  final endpoint = RpcResponderEndpoint(
    transport: transport,
    debugLabel: label,
  );
  endpoint.registerServiceContract(
    NotifySubscribeResponder(
      subscriber: INotifySubscriber.repository(repository),
    ),
  );
  endpoint.start();
  return endpoint;
}

void main() {
  group('a per-connection subscriber over a shared repository', () {
    test('releases its own topics and leaves the repository running', () async {
      final shared = _SpyRepository();
      final subscriber = INotifySubscriber.repository(shared);
      subscriber.subscribe('vault:x');

      // What rpc_dart does to a contract when its endpoint closes.
      await subscriber.dispose();

      expect(
        shared.disposeCalls,
        0,
        reason:
            'the subscriber was handed the repository, it did not create it; '
            'disposing a borrowed singleton kills every other holder',
      );
      expect(
        shared.unsubscribed,
        ['vault:x'],
        reason: 'its own subscription must still be released, or it leaks',
      );
    });

    test('an owning subscriber still disposes the repository', () async {
      final own = _SpyRepository();
      final subscriber = INotifySubscriber.repository(
        own,
        ownsRepository: true,
      );
      subscriber.subscribe('vault:x');

      await subscriber.dispose();

      expect(own.disposeCalls, 1, reason: 'ownership must still mean cleanup');
    });

    test('one connection closing leaves another connection\'s subscription '
        'alive', () async {
      final shared = InMemoryNotifyRepository();
      addTearDown(shared.dispose);

      final (callerA, responderA) = RpcInMemoryTransport.pair();
      final (callerB, responderB) = RpcInMemoryTransport.pair();
      final endpointA = _serveConnection(responderA, shared, 'connA');
      final endpointB = _serveConnection(responderB, shared, 'connB');
      addTearDown(endpointA.close);

      final clientA = NotifySubscriber.endpoint(
        RpcCallerEndpoint(transport: callerA, debugLabel: 'clientA'),
      );
      final clientB = NotifySubscriber.endpoint(
        RpcCallerEndpoint(transport: callerB, debugLabel: 'clientB'),
      );
      addTearDown(clientA.dispose);

      final received = <NotifyEvent>[];
      var done = false;
      clientA
          .subscribe('vault:x')
          .listen(
            received.add,
            onDone: () {
              done = true;
            },
          );
      // B's own stream dies with B's connection, which is correct and is not
      // what this test is about.
      clientB.subscribe('vault:x').listen((_) {}, onError: (Object _) {});
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(shared.subscriberCount('vault:x'), 2);

      shared.publish('vault:x', {'n': 1});
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(received.length, 1, reason: 'A is subscribed and healthy');

      // B's client disconnects. This is precisely what a transport server does
      // with a dropped connection: `_releaseEndpoint` -> `endpoint.close()`.
      await endpointB.close();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      shared.publish('vault:x', {'n': 2});
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(done, isFalse, reason: "B's disconnect closed A's notify stream");
      expect(
        received.length,
        2,
        reason:
            'the bus is shared, so B leaving stopped delivery to A as well — '
            'on a server that is every connected client at once',
      );
      expect(
        shared.subscriberCount('vault:x'),
        1,
        reason: "B's own subscription must be gone, A's must remain",
      );
    });

    test(
      'a resubscribe after the bus closed the stream gets a live one',
      () async {
        // The client's answer to a closed notify stream is to resubscribe. When
        // the subscriber cached the stream per topic, every attempt handed back
        // the CLOSED one — a late listener on a closed broadcast stream is done
        // at once — so the client looped on its backoff forever without ever
        // reattaching. That was the plugin's 31-second
        // "Notify stream closed — resubscribing".
        final repo = _ClosableRepository();
        final subscriber = INotifySubscriber.repository(repo);

        subscriber.subscribe('vault:x').listen((_) {});
        await repo.closeAllStreams();

        final received = <NotifyEvent>[];
        var doneImmediately = false;
        subscriber
            .subscribe('vault:x')
            .listen(received.add, onDone: () => doneImmediately = true);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        repo.emit('vault:x');
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(
          doneImmediately,
          isFalse,
          reason: 'resubscribing got a dead stream',
        );
        expect(
          received,
          hasLength(1),
          reason: 'and therefore delivered nothing',
        );
      },
    );
  });
}
