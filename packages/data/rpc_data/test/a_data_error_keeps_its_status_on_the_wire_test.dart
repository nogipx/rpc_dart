// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// rpc_dart forwards the status of an RpcStatusException only, and
// RpcDataError was not one: a version conflict, a permission denial and an
// overflowing watch all reached a remote client as status 13, and
// `on RpcDataError` caught none of them.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_data/rpc_data.dart';
import 'package:test/test.dart';

Future<DataServiceClient> _client({
  Iterable<String> tokens = const [],
}) async {
  final (clientT, serverT) = RpcChannelTransport.pair();
  final server = DataServiceServer(
    endpoint: RpcResponderEndpoint(transport: serverT),
    responder: DataServiceResponder(
      repository: InMemoryDataRepository(),
      transferMode: RpcDataTransferMode.codec,
      allowedBearerTokens: tokens,
    ),
    repository: InMemoryDataRepository(),
  );
  await server.start();
  final client = DataServiceFactory.createClient(transport: clientT);
  addTearDown(() async {
    await client.close();
    await server.close();
  });
  return client;
}

void main() {
  test('WITNESS a version conflict arrives as RpcDataError', () async {
    final client = await _client();
    final record = await client.create(collection: 'x', payload: {'a': 1});

    Object? caught;
    try {
      await client.update(
        collection: 'x',
        id: record.id,
        expectedVersion: record.version + 5,
        payload: {'a': 2},
      );
    } catch (e) {
      caught = e;
    }

    expect(
      caught,
      isA<RpcDataError>()
          .having((e) => e.status, 'status', RpcStatus.aborted)
          .having((e) => e.code, 'code', 'VERSION_CONFLICT'),
    );
  });

  test('a permission denial arrives with its status', () async {
    final client = await _client(tokens: ['secret']);
    await expectLater(
      client.create(collection: 'x', payload: {'a': 1}),
      throwsA(
        isA<RpcDataError>()
            .having((e) => e.status, 'status', RpcStatus.permissionDenied)
            .having((e) => e.code, 'code', 'PERMISSION_DENIED'),
      ),
    );
  });

  test('a denied watch fails as a stream, with its status', () async {
    final client = await _client(tokens: ['secret']);
    await expectLater(
      client.watchChanges(collection: 'x').first,
      throwsA(
        isA<RpcDataError>().having(
          (e) => e.status,
          'status',
          RpcStatus.permissionDenied,
        ),
      ),
    );
  });

  test('details survive the trip', () {
    final error = RpcDataError(
      'bad',
      status: RpcStatus.invalidArgument,
      code: 'SCHEMA',
      details: {'field': 'title', 'limit': 3, 'cause': 'secret'},
    );
    final back = RpcDataError.fromStatusException(error.toStatusException())!;
    expect(back.code, 'SCHEMA');
    expect(back.details, {'field': 'title', 'limit': 3});
  });

  test('an unrelated status is left alone', () {
    expect(
      RpcDataError.fromStatusException(
        const RpcStatusException(RpcStatus.notFound, 'nope'),
      ),
      isNull,
    );
  });
}
