// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// InMemoryNotifyRepository documented that distributors are "disposed when the
// last subscriber leaves". They never were: unsubscribe() only closed the
// client's stream, so every topic ever touched kept a StreamDistributor -- and
// its open broadcast controller -- for the repository's lifetime. publish()
// was worse: it created a distributor for a topic nobody is subscribed to,
// delivering the event to no one and retaining the distributor as its only
// lasting effect.
//
// Topic names come from clients, so both paths grew without bound. Neither was
// visible through activeTopics(), which counts only topics that still have
// subscribers -- hence trackedTopicCount, which counts what is actually held.

import 'package:rpc_notify/rpc_notify.dart';
import 'package:test/test.dart';

void main() {
  group('InMemoryNotifyRepository retains no per-topic state', () {
    test('a topic is released when its last subscriber leaves', () async {
      final repo = InMemoryNotifyRepository();

      for (var i = 0; i < 20; i++) {
        final topic = 'topic-$i';
        final sub = repo.subscribe('client', topic).listen((_) {});
        repo.unsubscribe('client', topic);
        await sub.cancel();
      }

      expect(
        repo.trackedTopicCount,
        0,
        reason: 'every unsubscribed topic kept its distributor before the fix',
      );
      expect(repo.activeTopics(), isEmpty);
      await repo.dispose();
    });

    test('a topic is kept while other subscribers remain', () async {
      final repo = InMemoryNotifyRepository();

      final a = repo.subscribe('a', 'shared').listen((_) {});
      final b = repo.subscribe('b', 'shared').listen((_) {});

      repo.unsubscribe('a', 'shared');
      expect(repo.trackedTopicCount, 1, reason: 'b is still subscribed');
      expect(repo.subscriberCount('shared'), 1);

      repo.unsubscribe('b', 'shared');
      expect(repo.trackedTopicCount, 0);

      await a.cancel();
      await b.cancel();
      await repo.dispose();
    });

    test('publishing to an unsubscribed topic retains nothing', () async {
      final repo = InMemoryNotifyRepository();

      for (var i = 0; i < 20; i++) {
        repo.publish('ghost-$i', {'n': i});
        repo.publishTo('nobody', 'ghost-to-$i', {'n': i});
      }

      expect(
        repo.trackedTopicCount,
        0,
        reason: 'publishing to nobody must not materialise a distributor',
      );
      await repo.dispose();
    });

    test('delivery still works for a live subscriber', () async {
      final repo = InMemoryNotifyRepository();
      final received = <String>[];
      final sub = repo
          .subscribe('client', 'live')
          .listen((e) => received.add(e.payload['msg'] as String));

      await Future<void>.delayed(const Duration(milliseconds: 20));
      repo.publish('live', {'msg': 'hello'});
      repo.publishTo('client', 'live', {'msg': 'direct'});
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(received, containsAll(<String>['hello', 'direct']));
      expect(repo.trackedTopicCount, 1);

      await sub.cancel();
      await repo.dispose();
    });
  });
}
