// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A remote subscriber that stops reading stops granting flow-control credit,
// the server's response stream pauses, and a paused subscription to the
// repository's broadcast stream buffers without limit. The responder holds
// a bounded number of events for it and drops the rest.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_notify/rpc_notify.dart';
import 'package:rpc_notify/src/server/paused_subscriber_bound.dart';
import 'package:test/test.dart';

const _kib = 1024;

Future<
  ({
    NotifySubscribeResponder responder,
    InMemoryNotifyRepository repo,
    NotifySubscribeContractCaller caller,
  })
>
_setUp({int maxPendingEvents = 1024, int maxPendingBytes = 8 << 20}) async {
  final (client, server) = RpcChannelTransport.pair();
  final repo = InMemoryNotifyRepository();
  final responder = NotifySubscribeResponder(
    subscriber: INotifySubscriber.repository(repo),
    maxPendingEvents: maxPendingEvents,
    maxPendingBytes: maxPendingBytes,
  );
  final serverEndpoint = RpcResponderEndpoint(transport: server)
    ..registerServiceContract(responder)
    ..start();
  final clientEndpoint = RpcCallerEndpoint(transport: client)..start();
  addTearDown(() async {
    await clientEndpoint.close();
    await serverEndpoint.close();
    await repo.dispose();
  });
  return (
    responder: responder,
    repo: repo,
    caller: NotifySubscribeContractCaller(clientEndpoint),
  );
}

Map<String, dynamic> _payload(int i, int size) => {
  'i': i,
  'd': String.fromCharCodes(List<int>.filled(size, 97 + i % 26)),
};

void main() {
  test(
    'WITNESS events for a subscriber that stopped reading are bounded',
    () async {
      final s = await _setUp(maxPendingBytes: 1024 * _kib);
      final sub = s.caller
          .subscribe(NotifySubscribeRequest(topic: 't'))
          .listen((_) {});
      addTearDown(sub.cancel);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      sub.pause();

      for (var i = 0; i < 400; i++) {
        s.repo.publish('t', _payload(i, 64 * _kib));
        if (i % 20 == 0) await Future<void>.delayed(Duration.zero);
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));

      // 1 MiB of 64 KiB events is 16; flow control takes a window's worth.
      expect(
        s.responder.droppedEvents,
        greaterThan(200),
        reason: 'the server kept what a paused subscriber did not read',
      );
    },
  );

  test('a short stall within the bound loses nothing', () async {
    final s = await _setUp();
    final received = <int>[];
    final sub = s.caller
        .subscribe(NotifySubscribeRequest(topic: 't'))
        .listen((e) => received.add(e.payload['i'] as int));
    addTearDown(sub.cancel);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    sub.pause();
    for (var i = 0; i < 50; i++) {
      s.repo.publish('t', _payload(i, 16));
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
    sub.resume();

    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (received.length < 50 && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(received, List<int>.generate(50, (i) => i));
    expect(s.responder.droppedEvents, 0);
  });

  group('boundWhilePaused', () {
    NotifyEvent event(int i) =>
        NotifyEvent(topic: 't', payload: {'i': i}, timestamp: DateTime(2026));

    test('holds events while paused and delivers them in order', () async {
      final source = StreamController<NotifyEvent>.broadcast();
      final got = <int>[];
      final sub = boundWhilePaused(
        source.stream,
        maxEvents: 100,
        maxBytes: 1 << 20,
      ).listen((e) => got.add(e.payload['i'] as int));
      sub.pause();
      for (var i = 0; i < 10; i++) {
        source.add(event(i));
      }
      await Future<void>.delayed(Duration.zero);
      expect(got, isEmpty);
      sub.resume();
      await Future<void>.delayed(Duration.zero);
      expect(got, List<int>.generate(10, (i) => i));
      await sub.cancel();
      await source.close();
    });

    test('drops past maxEvents and never pauses the source', () async {
      var pauses = 0;
      final source = StreamController<NotifyEvent>(onPause: () => pauses++);
      var dropped = 0;
      final got = <int>[];
      final sub = boundWhilePaused(
        source.stream,
        maxEvents: 3,
        maxBytes: 1 << 20,
        onDrop: () => dropped++,
      ).listen((e) => got.add(e.payload['i'] as int));
      sub.pause();
      for (var i = 0; i < 10; i++) {
        source.add(event(i));
      }
      await Future<void>.delayed(Duration.zero);
      sub.resume();
      await Future<void>.delayed(Duration.zero);
      expect(got, [0, 1, 2]);
      expect(dropped, 7);
      expect(pauses, 0);
      await sub.cancel();
      await source.close();
    });
  });
}
