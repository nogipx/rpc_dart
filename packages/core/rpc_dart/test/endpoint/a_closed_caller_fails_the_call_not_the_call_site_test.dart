// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A call on a closed caller fails through what the call returns -- a Future
// that completes with the error, a Stream that emits it -- as clientStream
// already did. Thrown at the call site instead, it bypasses `.catchError`, a
// Stream's onError, and every other non-`try` way of handling it.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

Future<RpcCallerEndpoint> _closedCaller() async {
  final (client, server) = RpcChannelTransport.pair();
  final caller = RpcCallerEndpoint(transport: client);
  await caller.close();
  addTearDown(server.close);
  return caller;
}

void main() {
  test('unary', () async {
    final caller = await _closedCaller();
    late Future<RpcString> call;
    expect(
      () => call = caller.unaryRequest<RpcString, RpcString>(
        serviceName: 'S',
        methodName: 'M',
        request: 'q'.rpc,
        requestCodec: _codec,
        responseCodec: _codec,
      ),
      returnsNormally,
    );
    await expectLater(call, throwsA(isA<RpcClosedException>()));
  });

  test('server-stream', () async {
    final caller = await _closedCaller();
    late Stream<RpcString> call;
    expect(
      () => call = caller.serverStream<RpcString, RpcString>(
        serviceName: 'S',
        methodName: 'M',
        request: 'q'.rpc,
        requestCodec: _codec,
        responseCodec: _codec,
      ),
      returnsNormally,
    );
    await expectLater(call, emitsError(isA<RpcClosedException>()));
  });

  test('bidi', () async {
    final caller = await _closedCaller();
    late Stream<RpcString> call;
    expect(
      () => call = caller.bidirectionalStream<RpcString, RpcString>(
        serviceName: 'S',
        methodName: 'M',
        requests: const Stream.empty(),
        requestCodec: _codec,
        responseCodec: _codec,
      ),
      returnsNormally,
    );
    await expectLater(call, emitsError(isA<RpcClosedException>()));
  });

  test('CONTROL client-stream', () async {
    final caller = await _closedCaller();
    late Future<RpcString> call;
    expect(
      () => call = caller.clientStream<RpcString, RpcString>(
        serviceName: 'S',
        methodName: 'M',
        requestCodec: _codec,
        responseCodec: _codec,
      )(const Stream.empty()),
      returnsNormally,
    );
    await expectLater(call, throwsA(isA<RpcClosedException>()));
  });
}
