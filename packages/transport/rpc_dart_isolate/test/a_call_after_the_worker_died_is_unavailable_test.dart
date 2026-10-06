// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A call after the PEER went away is UNAVAILABLE on every transport. A call
// after this side closed its own transport is still FAILED_PRECONDITION.

@TestOn('vm')
library;

import 'dart:async';
import 'dart:isolate';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_isolate/rpc_dart_isolate.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Svc extends RpcResponderContract {
  _Svc() : super('Svc');
  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'Echo',
      handler: (r, {RpcContext? context}) async => r,
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'Exit',
      handler: (r, {RpcContext? context}) async {
        Timer(const Duration(milliseconds: 50), () => Isolate.exit());
        return 'bye'.rpc;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

@pragma('vm:entry-point')
void _worker(IRpcTransport transport, Map<String, dynamic> params) {
  RpcResponderEndpoint(transport: transport)
    ..registerServiceContract(_Svc())
    ..start();
}

Future<int?> _echo(RpcCallerEndpoint caller) async {
  try {
    await caller.unaryRequest<RpcString, RpcString>(
      serviceName: 'Svc',
      methodName: 'Echo',
      request: 'x'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    );
    return null;
  } on RpcStatusException catch (e) {
    return e.statusCode;
  }
}

void main() {
  test('a call after the worker exited by itself is UNAVAILABLE', () async {
    final spawned = await RpcIsolateTransport.spawn(entrypoint: _worker);
    final caller = RpcCallerEndpoint(transport: spawned.transport);
    addTearDown(spawned.kill);

    await caller.unaryRequest<RpcString, RpcString>(
      serviceName: 'Svc',
      methodName: 'Exit',
      request: 'x'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    );
    await Future<void>.delayed(const Duration(milliseconds: 500));

    expect(await _echo(caller), RpcStatus.unavailable);
  });

  test('a call after the in-memory peer closed is UNAVAILABLE', () async {
    final (client, server) = RpcChannelTransport.memoryPair();
    final caller = RpcCallerEndpoint(transport: client);
    addTearDown(caller.close);

    await server.close();
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(await _echo(caller), RpcStatus.unavailable);
  });

  test(
    'GUARD: a call after this side closed stays FAILED_PRECONDITION',
    () async {
      final (client, server) = RpcChannelTransport.memoryPair();
      addTearDown(server.close);
      await client.close();

      await expectLater(
        client.sendMetadata(1, RpcMetadata.forClientRequest('Svc', 'Echo')),
        throwsA(
          isA<RpcClosedException>().having(
            (e) => e.statusCode,
            'statusCode',
            RpcStatus.failedPrecondition,
          ),
        ),
      );
    },
  );
}
