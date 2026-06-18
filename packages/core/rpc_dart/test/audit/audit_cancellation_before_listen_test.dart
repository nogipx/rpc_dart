// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Audit finding: cancellation delivery in base_processor.dart gated addError on
// `&& <controller>.hasListener`. The request/response controllers are
// single-subscription StreamController<T>() (NOT broadcast). For a
// single-subscription controller, addError BEFORE a listener attaches is
// buffered and delivered when the listener subscribes. The hasListener gate
// skipped buffering, so a cancellation that fired before the consumer
// subscribed dropped the RpcCancelledException forever. The empty `catch (_) {}`
// also hid real failures.
//
// base_processor.dart (old, ~597/601 and ~989/993):
//   if (!_requestController.isClosed && _requestController.hasListener) {
//     _requestController.addError(cancelledException);
//   }
//
// Fix: drop the `&& hasListener` gate (keep only !isClosed) so the error is
// buffered for a late subscriber; replace the empty catch with a debug log.
//
// CONFIRMED-FIX if: cancelling BEFORE subscribing to the processor's stream
// still delivers the RpcCancelledException to the late subscriber.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

void main() {
  group('cancellation buffered for a late subscriber (no hasListener gate)', () {
    test(
        'StreamProcessor: cancel before subscribing still delivers '
        'RpcCancelledException to requests stream', () async {
      final token = RpcCancellationToken();
      final context = RpcContext.withCancellation(token);

      final (client, rawServer) = RpcInMemoryTransport.pair();

      // Zero-copy: in-memory transport, no codecs.
      final processor = StreamProcessor<RpcString, RpcString>(
        transport: rawServer,
        streamId: 1,
        serviceName: 'S',
        methodName: 'M',
        context: context,
      );

      // Cancel BEFORE anyone subscribes to `requests`.
      token.cancel('cancelled before listen');

      // Let the cancellation monitor run and buffer the error.
      await Future<void>.delayed(const Duration(milliseconds: 10));

      // Now subscribe (the late subscriber).
      final errorCompleter = Completer<Object>();
      processor.requests.listen(
        (_) {},
        onError: (Object e) {
          if (!errorCompleter.isCompleted) errorCompleter.complete(e);
        },
        onDone: () {
          if (!errorCompleter.isCompleted) {
            errorCompleter.completeError(
              StateError('stream closed without delivering cancellation'),
            );
          }
        },
      );

      final received = await errorCompleter.future
          .timeout(const Duration(seconds: 2));

      expect(
        received,
        isA<RpcCancelledException>(),
        reason: 'cancellation fired before subscription must be buffered and '
            'delivered to the late subscriber, not dropped',
      );

      await processor.close();
      await client.close();
      await rawServer.close();
    });

    test(
        'CallProcessor: cancel before subscribing still delivers '
        'RpcCancelledException to responses stream', () async {
      final token = RpcCancellationToken();
      final context = RpcContext.withCancellation(token);

      final (client, rawServer) = RpcInMemoryTransport.pair();

      // Zero-copy: in-memory transport, no codecs.
      final processor = CallProcessor<RpcString, RpcString>(
        transport: client,
        serviceName: 'S',
        methodName: 'M',
        context: context,
      );

      // Cancel BEFORE anyone subscribes to `responses`.
      token.cancel('cancelled before listen');

      await Future<void>.delayed(const Duration(milliseconds: 10));

      final errorCompleter = Completer<Object>();
      processor.responses.listen(
        (_) {},
        onError: (Object e) {
          if (!errorCompleter.isCompleted) errorCompleter.complete(e);
        },
        onDone: () {
          if (!errorCompleter.isCompleted) {
            errorCompleter.completeError(
              StateError('stream closed without delivering cancellation'),
            );
          }
        },
      );

      final received = await errorCompleter.future
          .timeout(const Duration(seconds: 2));

      expect(
        received,
        isA<RpcCancelledException>(),
        reason: 'cancellation fired before subscription must be buffered and '
            'delivered to the late subscriber, not dropped',
      );

      await processor.close();
      await client.close();
      await rawServer.close();
    });
  });
}
