// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Audit finding 7: responder_pipeline.dart:182 obtain(streamId) creates
// unbounded state for arbitrary streamIds with no cleanup.
//
//   final state = _respStreams.obtain(message.streamId);   // line 182
//
// obtain() is putIfAbsent — it always materializes a RpcResponderStreamState.
// A metadata-only message with NO methodPath and NO cancellation header falls
// through every branch of _processResponderMessage WITHOUT triggering any
// _cleanupStream. The state lingers forever. An unauthenticated peer can spray
// distinct stream IDs and grow responder memory without bound.
//
// We observe openStreams via collectEndpointMetrics()['openStreams'] which maps
// to _respStreams.length (responder_pipeline.dart:158).
//
// CORRECT behavior: such no-op frames must not accumulate unbounded state.
// CONFIRMED if openStreams keeps growing with each junk frame.
//
// fvm dart test test/audit/audit_responder_obtain_unbounded_test.dart

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

void main() {
  test('junk metadata frames accumulate unbounded responder state', () async {
    final (clientTransport, serverTransport) = RpcChannelTransport.memoryPair();

    final responder = RpcResponderEndpoint(transport: serverTransport);
    responder.start();

    // Send many metadata-only frames with NO methodPath and NO cancel header,
    // each on a distinct (client/odd) stream ID. Each one calls obtain() and
    // then falls through with no cleanup.
    const count = 50;
    for (var i = 0; i < count; i++) {
      final streamId = clientTransport.createStream(); // odd ids
      await clientTransport.sendMetadata(
        streamId,
        const RpcMetadata([]), // no methodPath, no headers
        endStream: false,
      );
    }

    // Let the responder process the delivered frames.
    await Future<void>.delayed(const Duration(milliseconds: 100));

    final metrics = responder.collectEndpointMetrics();
    final openStreams = metrics['openStreams'] as int;

    // Correct behavior: meaningless frames should not pile up unbounded state.
    expect(
      openStreams,
      lessThan(count),
      reason:
          'openStreams=$openStreams — obtain() accumulates state for junk '
          'stream IDs with no cleanup path',
    );

    await responder.close();
    await clientTransport.close();
  });
}
