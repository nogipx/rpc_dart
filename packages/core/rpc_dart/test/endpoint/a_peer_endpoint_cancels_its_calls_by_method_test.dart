// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A peer endpoint makes calls like a caller endpoint, so it tracks them the
// same way: a call in flight is counted per method and cancelled by method or
// by service, including one a peer contract made.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

/// A unary method that answers only once the test lets it.
final class _Slow extends RpcResponderContract {
  _Slow() : super('Slow');

  final Completer<void> release = Completer<void>();

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'wait',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (r, {RpcContext? context}) async {
        await release.future;
        return r;
      },
    );
  }
}

final class _SlowPeer extends RpcPeerContract {
  _SlowPeer(RpcPeerEndpoint endpoint) : super('Slow', endpoint);

  @override
  void setup() {}

  Future<RpcString> wait(String value) => callUnary<RpcString, RpcString>(
    methodName: 'wait',
    request: value.rpc,
    requestCodec: _codec,
    responseCodec: _codec,
  );
}

void main() {
  late RpcPeerEndpoint server;
  late RpcPeerEndpoint client;
  late _Slow service;

  setUp(() {
    final (a, b) = RpcChannelTransport.memoryPair();
    service = _Slow();
    server = RpcPeerEndpoint(transport: b)
      ..registerServiceContract(service)
      ..start();
    client = RpcPeerEndpoint(transport: a)..start();
  });

  tearDown(() async {
    if (!service.release.isCompleted) service.release.complete();
    await client.close();
    await server.close();
  });

  Future<Object?> outcome(Future<Object?> call) async {
    try {
      return await call.timeout(const Duration(seconds: 5));
    } catch (e) {
      return e;
    }
  }

  test('the endpoint counts and cancels a call by method', () async {
    final call = outcome(
      client.unaryRequest<RpcString, RpcString>(
        serviceName: 'Slow',
        methodName: 'wait',
        request: 'x'.rpc,
        requestCodec: _codec,
        responseCodec: _codec,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(client.activeCallCount('Slow', 'wait'), 1);

    expect(client.cancelMethod('Slow', 'wait', 'stop'), 1);
    expect(await call, isA<RpcCancelledException>());
    expect(client.activeCallCount('Slow', 'wait'), 0);
  });

  test('the endpoint cancels a peer contract\'s calls by service', () async {
    final contract = _SlowPeer(client);
    final call = outcome(contract.wait('x'));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(client.activeCallCount('Slow', 'wait'), 1);

    expect(client.cancelService('Slow', 'stop'), 1);
    expect(await call, isA<RpcCancelledException>());
    expect(client.activeCallCount('Slow', 'wait'), 0);
  });
}
