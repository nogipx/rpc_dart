// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Audit finding 8: drain() busy-waits and on timeout logs "forcing cleanup"
// but performs NO cleanup.
//
// responder_pipeline.dart:123-149:
//   while (_respStreams.length > 0 && DateTime.now().isBefore(deadline)) {
//     await Future<void>.delayed(const Duration(milliseconds: 50));
//   }
//   if (_respStreams.length > 0) {
//     _log.warning('Drain timeout — ... still active, forcing cleanup');
//   }
//
// The "forcing cleanup" branch only logged. No stream was closed, no state was
// removed, no transport stream ID was released. After drain() returned, the
// streams were still there — the opposite of what the log claims.
//
// We seed a genuinely-open stream: a bidirectional handler that never completes
// and ignores its cancellation token. drain() trips the token, the handler
// ignores it, the busy-wait runs to its deadline, and the "forcing cleanup"
// branch must then actually tear the stream down.
//
// NOTE: this seed was changed from finding 7's junk-frame path. After finding 7
// is fixed, empty metadata-only frames no longer materialize responder state,
// so they can no longer be used to seed a lingering stream. A real long-running
// handler that ignores cancellation is the faithful way to exercise drain's
// force-cleanup path.
//
// CORRECT behavior: after drain() times out, openStreams must be 0 (cleanup
// actually performed). CONFIRMED if streams remain after drain.
//
// fvm dart test test/audit/audit_drain_no_cleanup_test.dart

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

/// A bidi contract whose handler hangs forever and ignores cancellation.
final class _HangingContract extends RpcResponderContract {
  _HangingContract() : super('HangSvc');

  @override
  void setup() {
    addBidirectionalMethod<RpcString, RpcString>(
      methodName: 'Hang',
      requestCodec: RpcCodec(RpcString.fromJson),
      responseCodec: RpcCodec(RpcString.fromJson),
      handler: (requests, {RpcContext? context}) {
        // Never emits, never completes, ignores the cancellation token: the
        // stream stays open until force-cleanup tears it down.
        final controller = StreamController<RpcString>();
        return controller.stream;
      },
    );
  }
}

void main() {
  test('streams are force-cleaned after drain timeout', () async {
    final (clientTransport, serverTransport) = RpcChannelTransport.memoryPair();

    final responder = RpcResponderEndpoint(transport: serverTransport);
    responder.registerServiceContract(_HangingContract());
    responder.start();

    final caller = BidirectionalStreamCaller<RpcString, RpcString>(
      transport: clientTransport,
      serviceName: 'HangSvc',
      methodName: 'Hang',
      requestCodec: RpcCodec(RpcString.fromJson),
      responseCodec: RpcCodec(RpcString.fromJson),
    );
    caller.responses.listen((_) {}, onError: (_) {});

    // Open the stream on the server by sending a request.
    await caller.send('start'.rpc);

    // Wait until the responder has materialized the open stream.
    var before = 0;
    for (var i = 0; i < 50; i++) {
      before = responder.collectEndpointMetrics()['openStreams'] as int;
      if (before > 0) break;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(
      before,
      greaterThan(0),
      reason: 'precondition: a lingering open stream must exist',
    );

    // Drain with a short timeout; the handler ignores cancellation so the
    // busy-wait expires and the force-cleanup branch must remove the stream.
    final sw = Stopwatch()..start();
    await responder.drain(timeout: const Duration(milliseconds: 200));
    sw.stop();

    final after = responder.collectEndpointMetrics()['openStreams'] as int;

    expect(
      after,
      0,
      reason:
          'drain logged "forcing cleanup" but left $after stream(s) alive '
          '(was $before before, waited ${sw.elapsedMilliseconds}ms) — '
          'no cleanup is performed on timeout',
    );

    await caller.close();
    await responder.close();
    await clientTransport.close();
  });
}
