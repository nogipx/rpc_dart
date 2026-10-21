// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A drain cancels every running handler's token. A handler that ignores it and
// finishes later must not report success, and the caller must not be left
// waiting: the call is answered CANCELLED, on every call shape.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

/// Handlers that run until the test lets them finish, ignoring the token.
final class _Stubborn extends RpcResponderContract {
  _Stubborn() : super('Stubborn');

  final Completer<void> started = Completer<void>();
  final Completer<void> finish = Completer<void>();

  Future<void> _work() async {
    if (!started.isCompleted) started.complete();
    await finish.future;
  }

  @override
  void setup() {
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'server',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (r, {RpcContext? context}) async* {
        await _work();
        yield 'late'.rpc;
      },
    );
    addClientStreamMethod<RpcString, RpcString>(
      methodName: 'client',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (requests, {RpcContext? context}) async {
        await _work();
        return 'late'.rpc;
      },
    );
    addBidirectionalMethod<RpcString, RpcString>(
      methodName: 'bidi',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (requests, {RpcContext? context}) async* {
        await _work();
        yield 'late'.rpc;
      },
    );
  }
}

void main() {
  late RpcCallerEndpoint caller;
  late RpcResponderEndpoint responder;
  late _Stubborn service;

  setUp(() {
    final (client, server) = RpcChannelTransport.memoryPair();
    caller = RpcCallerEndpoint(transport: client);
    responder = RpcResponderEndpoint(transport: server);
    service = _Stubborn();
    responder.registerServiceContract(service);
    responder.start();
  });

  tearDown(() async {
    if (!service.finish.isCompleted) service.finish.complete();
    await caller.close();
    await responder.close();
  });

  /// Drains while the handler runs, then lets the handler finish.
  Future<Object> drainedOutcome(Future<Object?> call) async {
    await service.started.future.timeout(const Duration(seconds: 5));
    unawaited(responder.drain(timeout: const Duration(seconds: 2)));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    service.finish.complete();
    try {
      final value = await call.timeout(const Duration(seconds: 5));
      return 'value: $value';
    } on RpcStatusException catch (e) {
      return 'status ${e.statusCode}';
    } on TimeoutException {
      return 'no answer';
    }
  }

  final cancelled = 'status ${RpcStatus.cancelled}';

  test('a drained server stream is answered CANCELLED', () async {
    final call = caller
        .serverStream<RpcString, RpcString>(
          serviceName: 'Stubborn',
          methodName: 'server',
          request: 'x'.rpc,
          requestCodec: _codec,
          responseCodec: _codec,
        )
        .toList();
    expect(await drainedOutcome(call), cancelled);
  });

  test('a drained client stream is answered CANCELLED', () async {
    final call = caller.clientStream<RpcString, RpcString>(
      serviceName: 'Stubborn',
      methodName: 'client',
      requestCodec: _codec,
      responseCodec: _codec,
      requests: Stream.value('x'.rpc),
    );
    expect(await drainedOutcome(call), cancelled);
  });

  test('a drained bidi stream is answered CANCELLED', () async {
    final requests = StreamController<RpcString>();
    requests.add('x'.rpc);
    final call = caller
        .bidirectionalStream<RpcString, RpcString>(
          serviceName: 'Stubborn',
          methodName: 'bidi',
          requests: requests.stream,
          requestCodec: _codec,
          responseCodec: _codec,
        )
        .toList();
    expect(await drainedOutcome(call), cancelled);
    await requests.close();
  });
}
