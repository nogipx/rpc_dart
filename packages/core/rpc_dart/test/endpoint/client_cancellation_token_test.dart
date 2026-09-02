// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The server's cooperative-cancellation signal is the per-call
// RpcCancellationToken on the handler's context. drain() fires it
// ('server draining'); the grpc-timeout watchdog fires it ('deadline
// exceeded'). The client's own cancellation -- by far the most common trigger
// -- did not: _handleClientCancellation took a `reason` parameter and never
// used it, tearing the responder down without ever cancelling the token.
//
// Closing the responder stops a Stream handler at its next suspension point,
// but it says nothing to a handler that polls context.cancellationToken or
// awaits `cancelled`, which is the documented way to abandon long work. So a
// unary handler kept burning server resources for a caller that was already
// gone: a 3s job cancelled after 100ms ran the full 3s, 295 of 300 work units
// spent after the client had disconnected.
//
// Note this affects every transport EXCEPT HTTP/2: CallProcessor prefers a
// transport-level reset (IRpcStreamReset) and only falls back to the
// x-client-cancelled metadata notice when the transport has none.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

/// Work units executed by the cooperative unary handler.
int _workUnits = 0;

/// The reason the handler read off its own cancellation token, if any.
String? _observedReason;

/// Set once the server-stream handler has captured its context.
Completer<RpcContext>? _streamContext;

final class _Contract extends RpcResponderContract {
  _Contract() : super('Svc');

  @override
  void setup() {
    // A cooperative long job: 3s of work, abandoned as soon as the caller goes
    // away. Polling the token is the documented pattern.
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'work',
      handler: (request, {RpcContext? context}) async {
        for (var i = 0; i < 300; i++) {
          if (context!.cancellationToken?.isCancelled ?? false) {
            _observedReason = context.cancellationToken!.reason;
            break;
          }
          _workUnits++;
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        return 'done'.rpc;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );

    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'watch',
      handler: (request, {RpcContext? context}) async* {
        _streamContext?.complete(context!);
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
    _workUnits = 0;
    _observedReason = null;
    _streamContext = null;
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

  test('a client cancellation stops a cooperative handler', () async {
    final token = RpcCancellationToken();

    unawaited(
      caller
          .unaryRequest<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'work',
            request: 'x'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
            context: RpcContext.withCancellation(token),
          )
          // The caller gets RpcCancelledException; that part already worked.
          .catchError((Object _) => 'err'.rpc),
    );

    await Future<void>.delayed(const Duration(milliseconds: 100));
    final atCancel = _workUnits;
    expect(atCancel, greaterThan(0), reason: 'handler should have started');

    token.cancel('user pressed stop');

    // One poll interval is 10ms; 300ms is 30 of them. Pre-fix the handler ran
    // its full 3s regardless.
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(
      _workUnits - atCancel,
      lessThan(5),
      reason:
          'handler kept working after the client cancelled '
          '($atCancel units at cancel, $_workUnits now)',
    );
    expect(
      _observedReason,
      'user pressed stop',
      reason: "the client's cancellation reason must reach the handler",
    );
  });

  test('a client cancellation cancels the handler context token', () async {
    final captured = _streamContext = Completer<RpcContext>();
    final token = RpcCancellationToken();

    final sub = caller
        .serverStream<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: 'watch',
          request: 'x'.rpc,
          requestCodec: _codec,
          responseCodec: _codec,
          context: RpcContext.withCancellation(token),
        )
        .listen((_) {}, onError: (Object _) {});

    final serverContext = await captured.future.timeout(
      const Duration(seconds: 5),
    );
    expect(serverContext.cancellationToken, isNotNull);
    expect(serverContext.cancellationToken!.isCancelled, isFalse);

    token.cancel('client went away');

    // The token must trip, not merely the scope close around it. Awaiting the
    // token's own future proves a handler blocked on `cancelled` is released.
    await serverContext.cancellationToken!.cancelled.timeout(
      const Duration(seconds: 5),
      onTimeout: () =>
          fail('server handler token never fired on client cancellation'),
    );
    expect(serverContext.cancellationToken!.reason, 'client went away');

    await sub.cancel();
  });

  test('drain and deadline still fire the same token', () async {
    // Guards the contrast this fix is built on: all three server-side
    // cancellation paths now converge on the one token.
    final captured = _streamContext = Completer<RpcContext>();

    final sub = caller
        .serverStream<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: 'watch',
          request: 'x'.rpc,
          requestCodec: _codec,
          responseCodec: _codec,
        )
        .listen((_) {}, onError: (Object _) {});

    final serverContext = await captured.future.timeout(
      const Duration(seconds: 5),
    );

    unawaited(responder.drain(timeout: const Duration(seconds: 2)));
    await serverContext.cancellationToken!.cancelled.timeout(
      const Duration(seconds: 5),
      onTimeout: () => fail('drain did not fire the handler token'),
    );
    expect(serverContext.cancellationToken!.reason, 'server draining');

    await sub.cancel();
  });
}
