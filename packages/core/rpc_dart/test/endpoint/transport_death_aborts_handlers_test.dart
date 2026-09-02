// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The incoming stream closing is the only notice a responder gets that its
// peer is unreachable. It was logged and otherwise ignored, so a dropped
// connection left every in-flight handler running with nowhere to send, its
// cancellation token never fired, and its stream state never reclaimed.
//
// Measured by closing the transport under one in-flight call of each shape,
// against a handler doing 1ms units of work. Before:
//
//   unary  117 -> 415 units after teardown, token=false, openStreams=1
//   server 111 -> 372                       token=false, openStreams=1
//   client 132 -> 427                       token=false, openStreams=1
//   bidi   123 -> 385                       token=false, openStreams=1
//
// After, all four stop at the teardown with token=true and openStreams=0.
//
// Both directions reach this path: closing either end of a paired transport
// closes the channel, so the responder's incoming stream ends either way. That
// made a dropped connection an unbounded resource leak -- one abandoned handler
// plus one stream state per drop, which any peer can drive by opening streams
// against an expensive method and disconnecting.
//
// Cancellation and deadlines already tripped the token; this was the path that
// did not. Note the token is what stops a plain `async` handler: a unary or
// client-stream handler that ignores it still runs to completion, exactly as on
// those other paths. Streaming handlers stop regardless, because closing the
// responder cancels the subscription driving the generator.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

/// Completes when a handler has started and its context is live.
Map<String, Completer<void>> _started = {};

/// Completes with the reason when a handler's token is cancelled.
Map<String, Completer<String>> _cancelled = {};

/// Units of work each handler has done.
Map<String, int> _work = {};

Completer<void> _started_(String s) =>
    _started.putIfAbsent(s, () => Completer<void>());
Completer<String> _cancelled_(String s) =>
    _cancelled.putIfAbsent(s, () => Completer<String>());

/// Cooperative work loop: bumps a counter until its token trips.
Future<void> _burn(String shape, RpcContext? context) async {
  final token = context?.cancellationToken;
  unawaited(
    token?.cancelled.then((_) {
      final c = _cancelled_(shape);
      if (!c.isCompleted) c.complete(token.reason ?? '<no reason>');
    }),
  );
  final s = _started_(shape);
  if (!s.isCompleted) s.complete();

  while (!(token?.isCancelled ?? false)) {
    _work[shape] = (_work[shape] ?? 0) + 1;
    await Future<void>.delayed(const Duration(milliseconds: 1));
    if ((_work[shape] ?? 0) > 5000) return;
  }
}

final class _Contract extends RpcResponderContract {
  _Contract() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'unary',
      handler: (r, {RpcContext? context}) async {
        await _burn('unary', context);
        return 'u'.rpc;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'server',
      handler: (r, {RpcContext? context}) async* {
        final token = context?.cancellationToken;
        unawaited(
          token?.cancelled.then((_) {
            final c = _cancelled_('server');
            if (!c.isCompleted) c.complete(token.reason ?? '<no reason>');
          }),
        );
        final s = _started_('server');
        if (!s.isCompleted) s.complete();
        while (!(token?.isCancelled ?? false)) {
          _work['server'] = (_work['server'] ?? 0) + 1;
          yield 'y'.rpc;
          await Future<void>.delayed(const Duration(milliseconds: 1));
          if ((_work['server'] ?? 0) > 5000) return;
        }
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addClientStreamMethod<RpcString, RpcString>(
      methodName: 'client',
      handler: (reqs, {RpcContext? context}) async {
        await _burn('client', context);
        return 'c'.rpc;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addBidirectionalMethod<RpcString, RpcString>(
      methodName: 'bidi',
      handler: (reqs, {RpcContext? context}) async* {
        final token = context?.cancellationToken;
        unawaited(
          token?.cancelled.then((_) {
            final c = _cancelled_('bidi');
            if (!c.isCompleted) c.complete(token.reason ?? '<no reason>');
          }),
        );
        final s = _started_('bidi');
        if (!s.isCompleted) s.complete();
        while (!(token?.isCancelled ?? false)) {
          _work['bidi'] = (_work['bidi'] ?? 0) + 1;
          yield 'y'.rpc;
          await Future<void>.delayed(const Duration(milliseconds: 1));
          if ((_work['bidi'] ?? 0) > 5000) return;
        }
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'quick',
      handler: (r, {RpcContext? context}) async {
        final token = context?.cancellationToken;
        unawaited(
          token?.cancelled.then((_) {
            final c = _cancelled_('quick');
            if (!c.isCompleted) c.complete(token.reason ?? '<no reason>');
          }),
        );
        return 'q:${r.value}'.rpc;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

typedef _Rig = ({
  IRpcTransport client,
  IRpcTransport server,
  RpcCallerEndpoint caller,
  RpcResponderEndpoint responder,
});

_Rig _connect() {
  final (client, server) = RpcChannelTransport.pair();
  final caller = RpcCallerEndpoint(transport: client);
  final responder = RpcResponderEndpoint(transport: server);
  responder.registerServiceContract(_Contract());
  responder.start();
  return (client: client, server: server, caller: caller, responder: responder);
}

Future<void> _teardown(_Rig r) async {
  await r.caller.close();
  await r.responder.close();
  await r.client.close();
  await r.server.close();
}

/// Starts one in-flight call of [shape] and returns its (swallowed) future.
Future<void> _startCall(_Rig rig, String shape) {
  final requests = StreamController<RpcString>()..add('a'.rpc);
  switch (shape) {
    case 'unary':
      return rig.caller
          .unaryRequest<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'unary',
            request: 'x'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .then<void>((_) {})
          .catchError((Object _) {});
    case 'server':
      return rig.caller
          .serverStream<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'server',
            request: 'x'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .drain<void>()
          .catchError((Object _) {});
    case 'client':
      return rig.caller
          .clientStream<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'client',
            requestCodec: _codec,
            responseCodec: _codec,
          )(requests.stream)
          .then<void>((_) {})
          .catchError((Object _) {});
    default:
      return rig.caller
          .bidirectionalStream<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'bidi',
            requests: requests.stream,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .drain<void>()
          .catchError((Object _) {});
  }
}

void main() {
  setUp(() {
    _started = {};
    _cancelled = {};
    _work = {};
  });

  for (final side in ['server', 'client']) {
    group('the $side transport dying aborts in-flight handlers', () {
      for (final shape in ['unary', 'server', 'client', 'bidi']) {
        test(shape, () async {
          final rig = _connect();
          unawaited(_startCall(rig, shape));

          await _started_(shape).future.timeout(
            const Duration(seconds: 5),
            onTimeout: () => fail('the $shape handler never started'),
          );
          final atTeardown = _work[shape] ?? 0;
          expect(
            atTeardown,
            greaterThan(0),
            reason: 'the handler should be doing work before the drop',
          );

          await (side == 'server' ? rig.server : rig.client).close();

          final reason = await _cancelled_(shape).future.timeout(
            const Duration(seconds: 5),
            onTimeout: () => fail(
              'the $shape handler was never cancelled after the $side '
              'transport died: it keeps running with nowhere to send',
            ),
          );
          expect(reason, 'transport closed');

          // And the work actually stops, rather than the token merely firing.
          final atAbort = _work[shape] ?? 0;
          await Future<void>.delayed(const Duration(milliseconds: 300));
          expect(
            (_work[shape] ?? 0) - atAbort,
            lessThanOrEqualTo(1),
            reason: 'the handler kept working after being aborted',
          );

          expect(
            rig.responder.collectEndpointMetrics()['openStreams'],
            0,
            reason: 'the stream state should be reclaimed',
          );
          await _teardown(rig);
        });
      }
    });
  }

  group('unchanged behaviour', () {
    test('a normal call is unaffected and its token is never fired', () async {
      // The abort must not poison a call that already completed.
      final rig = _connect();
      final r = await rig.caller
          .unaryRequest<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'quick',
            request: 'hi'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .timeout(const Duration(seconds: 5));
      expect(r.value, 'q:hi');

      await rig.server.close();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(
        _cancelled_('quick').isCompleted,
        isFalse,
        reason: 'a finished call must not be cancelled by a later drop',
      );
      await _teardown(rig);
    });

    test('closing an idle endpoint aborts nothing', () async {
      final rig = _connect();
      await rig.server.close();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(rig.responder.collectEndpointMetrics()['openStreams'], 0);
      await _teardown(rig);
    });

    test('the caller still sees the connection failure', () async {
      // Aborting the responder side must not swallow the caller's error.
      final rig = _connect();
      final call = rig.caller
          .serverStream<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'server',
            request: 'x'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .drain<void>();

      await _started_('server').future.timeout(const Duration(seconds: 5));
      await rig.server.close();

      await expectLater(
        call.timeout(const Duration(seconds: 5)),
        throwsA(isA<RpcStatusException>()),
      );
      await _teardown(rig);
    });

    test('an ordinary cancellation still reports its own reason', () async {
      // 'transport closed' must not displace the caller's reason.
      final rig = _connect();
      final token = RpcCancellationToken();
      unawaited(
        rig.caller
            .serverStream<RpcString, RpcString>(
              serviceName: 'Svc',
              methodName: 'server',
              request: 'x'.rpc,
              requestCodec: _codec,
              responseCodec: _codec,
              context: RpcContext.withCancellation(token),
            )
            .drain<void>()
            .catchError((Object _) {}),
      );
      await _started_('server').future.timeout(const Duration(seconds: 5));
      token.cancel('user quit');

      final reason = await _cancelled_(
        'server',
      ).future.timeout(const Duration(seconds: 5));
      expect(reason, isNot('transport closed'));
      await _teardown(rig);
    });

    test('repeated connect/drop cycles leave nothing behind', () async {
      for (var i = 0; i < 10; i++) {
        _started = {};
        _cancelled = {};
        _work = {};
        final rig = _connect();
        unawaited(_startCall(rig, 'server'));
        await _started_('server').future.timeout(const Duration(seconds: 5));
        await rig.server.close();
        await _cancelled_('server').future.timeout(const Duration(seconds: 5));
        expect(rig.responder.collectEndpointMetrics()['openStreams'], 0);
        await _teardown(rig);
      }
    });
  });
}
