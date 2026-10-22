// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A bidi handler that produces at a steady pace must stop once its call is
// over, however the call ended: the client cancelling, the deadline passing or
// the server closing. A send on a finished call returns rather than throwing,
// so a handler left running would produce into nothing, and silently.
//
// The consumer reads everything, so backpressure is not what stops the
// handler.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

const _paceMs = 5;
const _settleMs = 250;

/// How many messages the handler must have sent before the ending.
///
/// The arms below require more than five, so that "it stopped" is not vacuous.
const _started = 6;

/// Waits until [done], or until [ceiling] expires.
///
/// **The ceiling is not the wait.** `_paceMs` is a `Future.delayed`, so "200 ms
/// reaches forty messages" is a bet on timer latency, and that bet loses under
/// `dart test`'s own suite concurrency. Waiting for the condition removes the
/// bet, and when it genuinely never holds the ceiling expires and the arm's own
/// `expect` says so.
Future<void> _until(
  bool Function() done, {
  Duration ceiling = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(ceiling);
  while (!done() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

final class _Contract extends RpcResponderContract {
  _Contract(this.onProduce) : super('Svc');

  final void Function() onProduce;

  @override
  void setup() {
    addBidirectionalMethod<RpcString, RpcString>(
      methodName: 'feed',
      handler: (requests, {RpcContext? context}) async* {
        for (var i = 0; i < 100000; i++) {
          onProduce();
          yield 'x'.rpc;
          await Future<void>.delayed(const Duration(milliseconds: _paceMs));
        }
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );

    addBidirectionalMethod<RpcString, RpcString>(
      methodName: 'count',
      handler: (requests, {RpcContext? context}) async* {
        for (var i = 0; i < 40; i++) {
          yield '$i'.rpc;
        }
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

/// Produced when the server has let the call go, and [_settleMs] later.
typedef _Reading = (int atEnd, int after);

/// How a call is ended once the handler is producing.
enum _Ending {
  clientCancels('the client cancels'),
  deadlinePasses('the deadline passes'),
  serverCloses('the server closes');

  const _Ending(this.label);

  final String label;
}

/// Runs the steady handler, ends its call by [ending], waits for the server to
/// let the call go and reads the handler's counter either side of a settle.
Future<_Reading> _run(_Ending ending) async {
  // Generous, so the reading measures the ending and not the window.
  final (client, server) = RpcChannelTransport.pair(
    policy: const RpcSecurityPolicy(flowControlWindowBytes: 8 * 1024 * 1024),
  );
  var produced = 0;
  final responder = RpcResponderEndpoint(transport: server)
    ..registerServiceContract(_Contract(() => produced++))
    ..start();
  final caller = RpcCallerEndpoint(transport: client);

  final requests = StreamController<RpcString>();
  final ended = Completer<void>();
  final sub = caller
      .bidirectionalStream<RpcString, RpcString>(
        serviceName: 'Svc',
        methodName: 'feed',
        requests: requests.stream,
        requestCodec: _codec,
        responseCodec: _codec,
        context: ending == _Ending.deadlinePasses
            ? RpcContext.empty().withTimeout(const Duration(seconds: 1))
            : null,
      )
      .listen(
        (_) {},
        onError: (Object _) {},
        onDone: () => ended.isCompleted ? null : ended.complete(),
      );

  await _until(() => produced >= _started);
  switch (ending) {
    case _Ending.clientCancels:
      await sub.cancel();
    case _Ending.deadlinePasses:
      await ended.future.timeout(const Duration(seconds: 10));
    case _Ending.serverCloses:
      await responder.close();
  }

  // The server learns of the ending over the transport; read the counter once
  // it has let the call go.
  await _until(() {
    final m = responder.collectEndpointMetrics();
    return m.openStreams == 0 && m.activeResponders == 0;
  });
  final atEnd = produced;
  await Future<void>.delayed(const Duration(milliseconds: _settleMs));
  final after = produced;

  await sub.cancel().catchError((Object _) {});
  await requests.close();
  await caller.close().catchError((Object _) {});
  await responder.close().catchError((Object _) {});
  await client.close();
  await server.close();
  return (atEnd, after);
}

void main() {
  for (final ending in _Ending.values) {
    test('WITNESS: the handler stops producing once ${ending.label}', () async {
      final (atEnd, after) = await _run(ending);

      // The handler must have STARTED, or "it stopped" is vacuous. `_run`
      // waits for this rather than sleeping, so a failure here means it never
      // started.
      expect(
        atEnd,
        greaterThanOrEqualTo(_started),
        reason: 'the handler never got going, even given the ceiling',
      );
      expect(
        after - atEnd,
        lessThanOrEqualTo(2),
        reason:
            'the handler produced ${after - atEnd} more messages in the '
            '${_settleMs}ms after its call was over ($atEnd -> $after)',
      );
    });
  }

  // GUARD: stopping at the ending must not mean stopping before it. A handler
  // that simply runs to the end of its source still delivers all of it.
  test('GUARD: a handler that ends by itself delivers all of it', () async {
    final (client, server) = RpcChannelTransport.pair();
    final responder = RpcResponderEndpoint(transport: server)
      ..registerServiceContract(_Contract(() {}))
      ..start();
    final caller = RpcCallerEndpoint(transport: client);

    const total = 40;
    final seen = await caller
        .bidirectionalStream<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: 'count',
          requests: const Stream.empty(),
          requestCodec: _codec,
          responseCodec: _codec,
        )
        .map((r) => r.value)
        .toList()
        .timeout(const Duration(seconds: 20));
    expect(seen, [for (var i = 0; i < total; i++) '$i']);

    await caller.close();
    await responder.close();
    await client.close();
    await server.close();
  });
}
