// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// x-client-cancelled is a control signal the responder ACTS on: a metadata
// frame carrying it tears the stream down. It was not in RpcHeaders.reserved,
// so it travelled as ordinary user metadata -- and a context that happened to
// carry the key killed its own call at the door:
//
//   (a) call with x-client-cancelled in context
//       outcome      : TimeoutException   <- no gRPC status, just a hang
//       handler runs : 0
//
// The caller got nothing back at all. _handleClientCancellation tears down
// without replying (correct for a real cancellation, where the client already
// knows), so the call sat until the 60s default timeout.
//
// Two defences: the key is now reserved, so it cannot be set from context
// metadata; and a call-OPENING frame can no longer be a cancellation, since
// cancelling a call in the same breath as opening it is not a coherent request.
//
// gRPC compatibility: x-client-cancelled and x-cancellation-reason are
// rpc_dart's own keys, NOT gRPC's. gRPC signals cancellation with HTTP/2
// RST_STREAM, which this package uses via IRpcStreamReset wherever the
// transport offers one; the metadata notice is only the fallback for transports
// with no reset primitive. Reserving these sends FEWER non-standard headers, so
// interop with a real gRPC peer can only improve.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

int _handlerCalls = 0;
Map<String, String> _seenByHandler = const {};
RpcCancellationToken? _serverToken;

final class _Contract extends RpcResponderContract {
  _Contract() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'echo',
      handler: (request, {RpcContext? context}) async {
        _handlerCalls++;
        _seenByHandler = context!.headers;
        return request;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );

    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'endless',
      handler: (request, {RpcContext? context}) async* {
        _serverToken = context!.cancellationToken;
        while (true) {
          yield 'v'.rpc;
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

void main() {
  late RpcChannelTransport client;
  late RpcChannelTransport server;
  late RpcCallerEndpoint caller;
  late RpcResponderEndpoint responder;

  setUp(() {
    _handlerCalls = 0;
    _seenByHandler = const {};
    _serverToken = null;
    final pair = RpcChannelTransport.pair();
    client = pair.$1;
    server = pair.$2;
    caller = RpcCallerEndpoint(transport: client);
    responder = RpcResponderEndpoint(transport: server);
    responder.registerServiceContract(_Contract());
    responder.start();
  });

  tearDown(() async {
    await caller.close();
    await responder.close();
    await client.close();
    await server.close();
  });

  test('the control keys are reserved', () {
    expect(RpcHeaders.isReserved(RpcHeaders.xClientCancelled), isTrue);
    expect(RpcHeaders.isReserved(RpcHeaders.xCancellationReason), isTrue);
    expect(RpcHeaders.isReserved('X-Client-Cancelled'), isTrue);

    // Compression negotiation rides the context by design and must stay open,
    // as must ordinary user metadata.
    expect(RpcHeaders.isReserved(RpcHeaders.grpcEncoding), isFalse);
    expect(RpcHeaders.isReserved(RpcHeaders.grpcAcceptEncoding), isFalse);
    expect(RpcHeaders.isReserved('authorization'), isFalse);
  });

  test(
    'a context carrying the cancel key does not kill its own call',
    () async {
      final result = await caller
          .unaryRequest<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'echo',
            request: 'hello'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
            context: RpcContext.withHeaders({
              RpcHeaders.xClientCancelled: 'true',
              RpcHeaders.xCancellationReason: 'injected',
              'authorization': 'Bearer real-token',
            }),
          )
          .timeout(
            const Duration(seconds: 5),
            onTimeout: () => fail('the call hung instead of being served'),
          );

      expect(result.value, 'hello');
      expect(_handlerCalls, 1, reason: 'the handler must actually run');
    },
  );

  test('the control keys never reach the wire, ordinary ones do', () async {
    await caller.unaryRequest<RpcString, RpcString>(
      serviceName: 'Svc',
      methodName: 'echo',
      request: 'hello'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
      context: RpcContext.withHeaders({
        RpcHeaders.xClientCancelled: 'true',
        RpcHeaders.xCancellationReason: 'injected',
        'authorization': 'Bearer real-token',
      }),
    );

    expect(_seenByHandler, isNot(contains(RpcHeaders.xClientCancelled)));
    expect(_seenByHandler, isNot(contains(RpcHeaders.xCancellationReason)));
    expect(
      _seenByHandler['authorization'],
      'Bearer real-token',
      reason: 'reserving control keys must not strip user metadata',
    );
  });

  test('real cancellation still reaches the server handler', () async {
    // The guard that matters: the cheap way to pass every test above is to stop
    // honouring the cancellation notice at all.
    final token = RpcCancellationToken();
    final sub = caller
        .serverStream<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: 'endless',
          request: 'x'.rpc,
          requestCodec: _codec,
          responseCodec: _codec,
          context: RpcContext.withCancellation(token),
        )
        .listen((_) {}, onError: (Object _) {});

    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(_serverToken, isNotNull, reason: 'the handler should have started');

    token.cancel('user pressed stop');

    await _serverToken!.cancelled.timeout(
      const Duration(seconds: 5),
      onTimeout: () => fail(
        'the cancellation notice no longer reaches the '
        'server -- the reserved-header change broke it',
      ),
    );
    expect(_serverToken!.reason, 'user pressed stop');

    await sub.cancel();
  });
}
