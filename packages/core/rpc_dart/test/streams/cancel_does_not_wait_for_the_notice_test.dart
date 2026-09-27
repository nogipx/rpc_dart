// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Cancelling a unary call hung for ever if the transport's end-of-stream send
// never completed.
//
// Two sites send a cancellation notice and then tear down, in opposite orders,
// and each carried a comment defending itself. The unary one said
// "_notifyPeerOfCancellation never throws", which is literally TRUE -- the
// shared helper wraps both the reset and the send in try/catch -- and is not the
// risk. It AWAITS `transport.sendMetadata`, and a catch does not catch a hang.
// The streaming sibling says exactly that, and sends the notice `unawaited`.
//
// Measured, before the fix:
//
//   unary,  hanging notice   NEVER SETTLED (hung)
//   unary,  normal notice    settled: RpcCancelledException
//   stream, hanging notice   settled: RpcCancelledException
//
// The ordering that is REAL is notice-before-id-release: a frame sent after the
// id is reclaimed lands on whatever call now holds the number. Awaiting the
// notice in the call's `finally` turned that into notice-before-RETURN, which is
// a different and much more expensive promise. The release is now chained onto
// the notice instead, off the call's critical path.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

import '../utils/transport_wrappers.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _SlowService extends RpcResponderContract {
  _SlowService() : super('Svc');

  @override
  void setup() {
    // Never answers, so the call is still in flight when it is cancelled.
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'slow',
      handler: (request, {RpcContext? context}) =>
          Completer<RpcString>().future,
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

/// Cancels an in-flight unary call and returns what its future did.
///
/// Returns `'hung'` when the future never settles, so a hang is an assertable
/// value rather than a test that times out.
Future<String> _cancelInFlight({required bool hangingNotice}) async {
  final (rawClient, server) = RpcChannelTransport.pair();
  final client = HangingEndOfStreamTransport(rawClient, hang: hangingNotice);
  final caller = RpcCallerEndpoint(transport: client);
  final responder = RpcResponderEndpoint(transport: server);
  responder.registerServiceContract(_SlowService());
  responder.start();

  final token = RpcCancellationToken();
  var outcome = 'hung';
  final settled = Completer<void>();

  unawaited(
    Future<void>(() async {
      try {
        await caller.unaryRequest<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: 'slow',
          request: 'x'.rpc,
          requestCodec: _codec,
          responseCodec: _codec,
          context: RpcContext.withCancellation(token),
        );
        outcome = 'returned a value';
      } catch (e) {
        outcome = '${e.runtimeType}';
      } finally {
        if (!settled.isCompleted) settled.complete();
      }
    }),
  );

  // Let the call reach the wire before cancelling it.
  await Future<void>.delayed(const Duration(milliseconds: 300));
  token.cancel('test');

  await settled.future.timeout(const Duration(seconds: 3), onTimeout: () {});

  await caller.close().catchError((Object _) {});
  await responder.close().catchError((Object _) {});
  await rawClient.close().catchError((Object _) {});
  await server.close().catchError((Object _) {});
  return outcome;
}

void main() {
  group('cancelling a unary call does not wait for the peer notice', () {
    // WITNESS. Before the fix this never settled at all.
    test(
      'a notice that never completes does not hang the call',
      () async {
        expect(
          await _cancelInFlight(hangingNotice: true),
          'RpcCancelledException',
          reason:
              'the cancellation is a local fact; a caller must learn of it '
              'without waiting on a network write that may never finish',
        );
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    // CONTROL. The same path with the notice completing normally. If this had
    // failed, the witness would have been measuring the harness.
    test(
      'CONTROL: a notice that completes normally still cancels',
      () async {
        expect(
          await _cancelInFlight(hangingNotice: false),
          'RpcCancelledException',
        );
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    // GUARD for what the removed `await` was actually protecting: the stream id
    // must still be released, or it leaks against maxActiveStreams on a path
    // that never calls finishSending().
    test(
      'GUARD: the stream id is still released after cancelling',
      () async {
        final (rawClient, server) = RpcChannelTransport.pair();
        final caller = RpcCallerEndpoint(transport: rawClient);
        final responder = RpcResponderEndpoint(transport: server);
        responder.registerServiceContract(_SlowService());
        responder.start();
        addTearDown(() async {
          await caller.close().catchError((Object _) {});
          await responder.close().catchError((Object _) {});
          await rawClient.close().catchError((Object _) {});
          await server.close().catchError((Object _) {});
        });

        final token = RpcCancellationToken();
        unawaited(
          caller
              .unaryRequest<RpcString, RpcString>(
                serviceName: 'Svc',
                methodName: 'slow',
                request: 'x'.rpc,
                requestCodec: _codec,
                responseCodec: _codec,
                context: RpcContext.withCancellation(token),
              )
              .catchError((Object _) => 'cancelled'.rpc),
        );
        await Future<void>.delayed(const Duration(milliseconds: 300));
        token.cancel('test');

        // Poll rather than sleep once: the release is now chained onto the notice,
        // so it lands a microtask or two after the call returns.
        var active = -1;
        for (var i = 0; i < 40; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          final health = await rawClient.health();
          active = (health.details['activeStreams'] as int?) ?? -1;
          if (active == 0) break;
        }

        expect(
          active,
          0,
          reason:
              'chaining the release onto the notice must still reclaim the id; '
              'the unary path never calls finishSending(), so nothing else does',
        );
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );
  });
}
