// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A remote watcher that stops reading stops granting flow-control credit,
// the server's response stream pauses, and the watch's MultiStreamController
// buffered every later change. The repository now holds a bounded number of
// live changes for it and ends the watch with RESOURCE_EXHAUSTED past that.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_data/rpc_data.dart';
import 'package:rpc_data/src/rpc/data_contract.dart';
import 'package:test/test.dart';

Future<(DataServiceClient, DataServiceContractCaller)> _setUp({
  RpcSecurityPolicy? rawPolicy,
}) async {
  final (clientT, serverT) = RpcChannelTransport.pair();
  final server = DataServiceFactory.createServer(
    transport: serverT,
    repository: InMemoryDataRepository(),
  );
  await server.start();
  final client = DataServiceFactory.createClient(transport: clientT);
  final (rawT, rawServerT) = RpcChannelTransport.pair(
    policy: rawPolicy ?? const RpcSecurityPolicy(),
  );
  final rawServer = DataServiceServer(
    endpoint: RpcResponderEndpoint(transport: rawServerT),
    responder: DataServiceResponder(
      repository: server.repository,
      disposeRepositoryOnClose: false,
      transferMode: RpcDataTransferMode.codec,
    ),
    repository: server.repository,
  );
  await rawServer.start();
  final rawEndpoint = RpcCallerEndpoint(transport: rawT)..start();
  addTearDown(() async {
    await rawEndpoint.close();
    await rawServer.close();
    await server.close();
  });
  return (client, DataServiceContractCaller(rawEndpoint));
}

Future<void> _update(DataServiceClient client, int times, int size) async {
  var record = await client.create(collection: 'notes', payload: {'d': ''});
  for (var i = 0; i < times; i++) {
    record = await client.update(
      collection: 'notes',
      id: record.id,
      expectedVersion: record.version,
      payload: {'d': String.fromCharCodes(List<int>.filled(size, 97 + i % 26))},
    );
  }
}

void main() {
  test('WITNESS a watcher that stopped reading has its watch ended', () async {
    final (client, raw) = await _setUp();
    Object? error;
    var received = 0;
    final sub = raw
        .watchChanges(WatchChangesRequest(collection: 'notes'))
        .listen((_) => received++, onError: (Object e) => error = e);
    addTearDown(sub.cancel);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    sub.pause();

    // 300 x 128 KiB is well past the 16 MiB a paused watcher may hold.
    await _update(client, 300, 128 * 1024);
    sub.resume();
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (error == null && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }

    expect(
      '$error',
      contains('The watcher stopped reading'),
      reason: 'the server kept every change a paused watcher did not read',
    );
    expect(received, lessThan(301));
  });

  test('a short stall within the bound loses nothing', () async {
    // A small window, so the server's stream really pauses and changes are
    // held by the repository rather than in flight.
    final (client, raw) = await _setUp(
      rawPolicy: const RpcSecurityPolicy(flowControlWindowBytes: 64 * 1024),
    );
    Object? error;
    var received = 0;
    final sub = raw
        .watchChanges(WatchChangesRequest(collection: 'notes'))
        .listen((_) => received++, onError: (Object e) => error = e);
    addTearDown(sub.cancel);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    sub.pause();
    await _update(client, 50, 8 * 1024);
    sub.resume();
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (received < 51 && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(received, 51);
    expect(error, isNull);
  });
}
