// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A server stream that ends on the CALLER side, for a reason the server cannot
// see, must still tell the server: otherwise its handler keeps producing and
// holds a handler slot until the connection closes. The same holds for bidi,
// whose bridge told the server only when its own request side failed.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

/// Responses the bidi handlers have produced, across both calls of a run.
var _produced = 0;

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

/// Shared by both streams, so it fails each one on its second response: the
/// 2nd and the 4th it sees. The unary call after them is not intercepted.
final class _RejectsSecond extends IRpcInterceptor {
  int _n = 0;

  Stream<T> _reject<T>(Stream<T> responses) async* {
    await for (final response in responses) {
      if (++_n == 2 || _n == 4) throw StateError('interceptor rejects');
      yield response;
    }
  }

  @override
  Future<Stream<TResponse>> interceptServerStream<TRequest, TResponse>(
    RpcCallInfo call,
    TRequest request,
    RpcServerStreamNext<TRequest, TResponse> next,
  ) async => _reject(await next(call.context, request));

  @override
  Future<Stream<TResponse>> interceptBidirectionalStream<TRequest, TResponse>(
    RpcCallInfo call,
    Stream<TRequest> requests,
    RpcBidirectionalStreamNext<TRequest, TResponse> next,
  ) async => _reject(await next(call.context, requests));
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
    addBidirectionalMethod<RpcString, RpcString>(
      methodName: 'chat',
      handler: (requests, {RpcContext? context}) async* {
        var i = 0;
        while (true) {
          _produced++;
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
  IRpcInterceptor Function()? interceptor,
  bool consumerLeaves = false,
  bool bidi = false,
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

  if (interceptor != null) caller.addInterceptor(interceptor());
  for (var k = 0; k < 2; k++) {
    final stream = bidi
        ? caller.bidirectionalStream<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'chat',
            // Never ends: the bidi handler must not stop on a half-close.
            requests: StreamController<RpcString>().stream,
            requestCodec: _codec,
            responseCodec: responseCodec?.call() ?? _codec,
          )
        : caller.serverStream<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'ticks',
            request: 'a'.rpc,
            requestCodec: _codec,
            responseCodec: responseCodec?.call() ?? _codec,
          );
    if (consumerLeaves) {
      await for (final _ in stream) {
        break;
      }
      continue;
    }
    // A consumer that takes the error and keeps listening: it does not
    // cancel, so the cancellation token never tells the server.
    final done = Completer<void>();
    stream.listen((_) {}, onError: (Object _) {}, onDone: done.complete);
    await done.future.timeout(const Duration(seconds: 5), onTimeout: () {});
  }

  if (bidi) {
    // What the handler produces after its call ended, the observable the
    // probe that found this used.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final settled = _produced;
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(
      _produced - settled,
      0,
      reason: 'a bidi handler kept producing for a call its caller ended',
    );
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

  test('a caller interceptor that fails the stream', () async {
    await _run(interceptor: _RejectsSecond.new);
  });

  test('control: the consumer leaves', () async {
    await _run(consumerLeaves: true);
  });

  test('bidi: a response the caller cannot decode', () async {
    await _run(responseCodec: _FailsOnSecond.new, bidi: true);
  });

  test('bidi: a caller interceptor that fails the stream', () async {
    await _run(interceptor: _RejectsSecond.new, bidi: true);
  });

  test('bidi control: the consumer leaves', () async {
    await _run(consumerLeaves: true, bidi: true);
  });
}
