// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT
@TestOn('vm || node')
library;

import 'dart:async';

import 'package:rpc_data/rpc_data.dart';
import 'package:test/test.dart';

void main() {
  test('direct-repo watchChanges + cancel (web)', () async {
    final repo = InMemoryDataRepository();
    final client = DataRepositoryClient(repository: repo);

    final got = <DataChangeEvent>[];
    final sub = client.watchChanges(collection: 'c').listen(got.add);
    await Future<void>.delayed(const Duration(milliseconds: 10));

    await client.create(collection: 'c', payload: {'v': 1});
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(got.length, 1);

    // Exercise cancel (the dart2js deadlock pattern).
    await sub.cancel().timeout(const Duration(seconds: 3));
    await repo.dispose();
  });

  test('direct-repo exportDatabase + cancel (web)', () async {
    final repo = InMemoryDataRepository();
    final client = DataRepositoryClient(repository: repo);
    await client.create(collection: 'c', payload: {'v': 1});

    final sub = client.exportDatabase().listen((_) {});
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await sub.cancel().timeout(const Duration(seconds: 3));
    await repo.dispose();
  });

  test('RPC watchChanges streams events (web)', () async {
    final env = await DataServiceFactory.inMemory();
    final first = Completer<DataChangeEvent>();
    final sub = env.client.watchChanges(collection: 'c').listen((event) {
      if (!first.isCompleted) first.complete(event);
    });

    // The server-stream round-trip plus journal replay can outlast a fixed
    // delay on dart2js/node, so drive creates until the live event lands
    // instead of racing a single timer.
    while (!first.isCompleted) {
      await env.client.create(collection: 'c', payload: {'v': 1});
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }

    final event = await first.future.timeout(const Duration(seconds: 5));
    expect(event.collection, 'c');
    await sub.cancel();
    await env.dispose();
  });
}
