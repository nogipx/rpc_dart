// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A peer hanging up must not be able to end the server process.
//
// The responder pipeline detaches its teardown work — cancellation, cleanup,
// error replies — because by then there is no caller left to report to. Those
// were bare `unawaited(...)`, so anything they threw went to the zone, and a
// Dart server with no zone error handler exits on that.
//
// It was not theoretical. A client abandoning a coalesced blob download
// cancels with its own reason; _handleClientCancellation cancels the
// server-side token with that reason and closes the responder; the aborted
// handler raises RpcCancelledException — and both production replicas exited
// 255 within hours of each other, taking the notify fanout with them, because
// nothing was left alive to hold the Redis connection.
//
// `whenComplete` is the specific trap: it re-raises whatever the future
// carried, so `unawaited(responder.done.whenComplete(cleanup))` turns any
// handler failure into an uncaught zone error.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _ThrowsOnCancelContract extends RpcResponderContract {
  _ThrowsOnCancelContract() : super('Svc');

  @override
  void setup() {
    // Models a handler aborted mid-flight: it notices the cancellation and
    // fails rather than returning quietly. A blob pump that raises on a
    // cancelled read is exactly this.
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'watch',
      handler: (request, {RpcContext? context}) async* {
        while (true) {
          if (context!.cancellationToken?.isCancelled ?? false) {
            throw StateError(
              'handler aborted: ${context.cancellationToken!.reason}',
            );
          }
          yield 'v'.rpc;
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

void main() {
  test('a client cancelling cannot take the process down', () async {
    final uncaught = <Object>[];
    final finished = Completer<void>();

    runZonedGuarded(
      () async {
        final pair = RpcChannelTransport.pair();
        final caller = RpcCallerEndpoint(transport: pair.$1);
        final responder = RpcResponderEndpoint(transport: pair.$2);
        responder.registerServiceContract(_ThrowsOnCancelContract());
        responder.start();

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

        // Let the handler get going, then hang up the way a client does when
        // the last subscriber of a coalesced transfer leaves.
        await Future<void>.delayed(const Duration(milliseconds: 60));
        token.cancel('last subscriber left');

        // Long enough for the teardown to run and for anything it throws to
        // reach the zone.
        await Future<void>.delayed(const Duration(milliseconds: 300));

        await sub.cancel();
        await caller.close();
        await responder.close();
        await pair.$1.close();
        await pair.$2.close();
        finished.complete();
      },
      (Object error, StackTrace stack) {
        uncaught.add(error);
        if (!finished.isCompleted) finished.complete();
      },
    );

    await finished.future;

    expect(
      uncaught,
      isEmpty,
      reason:
          'a detached teardown threw into the zone. In a server process that '
          'is exit(255) — which is how a client abandoning a download killed '
          'both replicas. Errors here have no caller left to reach and must '
          'be logged, never raised: ${uncaught.isEmpty ? '' : uncaught.first}',
    );
  });
}
