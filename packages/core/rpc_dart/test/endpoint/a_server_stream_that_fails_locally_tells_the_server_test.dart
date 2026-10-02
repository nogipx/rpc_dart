// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A server stream that ends on the CALLER side, for a reason the server cannot
// see, must still tell the server: otherwise its handler keeps producing and
// holds a handler slot until the connection closes.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

/// Decodes the first response and refuses the second.
final class _FailsOnSecond implements IRpcCodec<RpcString> {
  int _n = 0;

  @override
  Uint8List serialize(RpcString message) => _codec.serialize(message);

  @override
  RpcString deserialize(Uint8List bytes) {
    if (++_n == 2) throw const FormatException('undecodable');
    return _codec.deserialize(bytes);
  }
}

/// Shared by both streams, so it rejects each one's second response: the
/// 2nd and the 4th it sees. The unary call after them passes.
final class _RejectsSecond extends IRpcMiddleware {
  int _n = 0;

  @override
  FutureOr<TResponse> processResponse<TResponse>(
    RpcMiddlewareContext call,
    TResponse response,
  ) {
    if (++_n == 2 || _n == 4) throw StateError('middleware rejects');
    return response;
  }
}

final class _Ticks extends RpcResponderContract {
  _Ticks() : super('Svc');

  @override
  void setup() {
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'ticks',
      handler: (request, {RpcContext? context}) async* {
        var i = 0;
        while (true) {
          yield '${i++}'.rpc;
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'ping',
      handler: (request, {RpcContext? context}) async => 'pong'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

Future<void> _waitFor(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<void> _run({
  IRpcCodec<RpcString> Function()? responseCodec,
  IRpcMiddleware Function()? middleware,
  bool consumerLeaves = false,
}) async {
  const policy = RpcSecurityPolicy(maxConcurrentHandlers: 2);
  final (client, server) = RpcChannelTransport.pair(policy: policy);
  final caller = RpcCallerEndpoint(transport: client);
  final responder = RpcResponderEndpoint(transport: server)
    ..registerServiceContract(_Ticks())
    ..start();
  addTearDown(() async {
    await caller.close();
    await responder.close();
  });

  if (middleware != null) caller.addMiddleware(middleware());
  for (var k = 0; k < 2; k++) {
    final stream = caller.serverStream<RpcString, RpcString>(
      serviceName: 'Svc',
      methodName: 'ticks',
      request: 'a'.rpc,
      requestCodec: _codec,
      responseCodec: responseCodec?.call() ?? _codec,
    );
    try {
      await for (final _ in stream) {
        if (consumerLeaves) break;
      }
    } catch (_) {}
  }

  await _waitFor(() => responder.activeResponderCount == 0);
  expect(
    responder.activeResponderCount,
    0,
    reason: 'the server still runs a handler for a call its caller ended',
  );
  final answer = await caller.unaryRequest<RpcString, RpcString>(
    serviceName: 'Svc',
    methodName: 'ping',
    request: 'x'.rpc,
    requestCodec: _codec,
    responseCodec: _codec,
  );
  expect(answer.value, 'pong');
}

void main() {
  test('a response the caller cannot decode', () async {
    await _run(responseCodec: _FailsOnSecond.new);
  });

  test('a caller response middleware that throws', () async {
    await _run(middleware: _RejectsSecond.new);
  });

  test('control: the consumer leaves', () async {
    await _run(consumerLeaves: true);
  });
}
