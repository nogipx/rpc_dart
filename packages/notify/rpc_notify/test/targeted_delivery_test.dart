// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_notify/src/stream_distributor.dart';
import 'package:test/test.dart';

void main() {
  test(
    'mixed publications retain order and count each delivery once',
    () async {
      final distributor = StreamDistributor<RpcInt>();
      addTearDown(distributor.dispose);
      final a = <int>[];
      final b = <int>[];
      final lateClient = <int>[];
      final subA = distributor
          .createClientStreamWithId('a')
          .listen((v) => a.add(v.value));
      final subB = distributor
          .createClientStreamWithId('b')
          .listen((v) => b.add(v.value));
      addTearDown(subA.cancel);
      addTearDown(subB.cancel);
      distributor.publish(1.rpc);
      distributor.publishToClient('a', 2.rpc);
      distributor.publishFiltered(3.rpc, (client) => client.clientId == 'a');
      final subLate = distributor
          .createClientStreamWithId('late')
          .listen((v) => lateClient.add(v.value));
      addTearDown(subLate.cancel);
      await Future<void>.delayed(Duration.zero);
      expect(a, [1, 2, 3]);
      expect(b, [1]);
      expect(lateClient, isEmpty);
      expect(distributor.getClientInfo('a')!['messagesReceived'], 3);
      expect(distributor.getClientInfo('b')!['messagesReceived'], 1);
      expect(distributor.metrics.totalMessages, 3);
    },
  );

  test(
    'a queued delivery cannot reach a replacement with the same id',
    () async {
      final distributor = StreamDistributor<RpcInt>();
      addTearDown(distributor.dispose);
      final old = distributor.createClientStreamWithId('a').listen((_) {});
      addTearDown(old.cancel);
      distributor.publishToClient('a', 1.rpc);
      final closing = distributor.closeClientStream('a');
      final received = <int>[];
      final replacement = distributor
          .createClientStreamWithId('a')
          .listen((v) => received.add(v.value));
      addTearDown(replacement.cancel);
      await closing;
      distributor.publishToClient('a', 2.rpc);
      await Future<void>.delayed(Duration.zero);
      expect(received, [2]);
      expect(distributor.getClientInfo('a')!['messagesReceived'], 1);
    },
  );

  test(
    'dispose closes every client stream and resets active metrics',
    () async {
      final distributor = StreamDistributor<RpcInt>();
      final done = Completer<void>();
      final sub = distributor
          .createClientStreamWithId('a')
          .listen((_) {}, onDone: done.complete);
      await distributor.dispose();
      await done.future.timeout(const Duration(seconds: 1));
      expect(distributor.metrics.currentStreams, 0);
      expect(distributor.activeClientCount, 0);
      await sub.cancel();
    },
  );
}
