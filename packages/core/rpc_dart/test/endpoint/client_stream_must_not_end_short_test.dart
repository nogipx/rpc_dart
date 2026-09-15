// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A client-stream must never END while one of its messages is still waiting to
// be sent.
//
// This is the defect behind a consumer's blob uploads. The server reported, over
// and over:
//
//   Bad state: Declared length 2442197 does not match received 524288 bytes.
//
// and the client retried the same blob fifteen times, each attempt refused. The
// connection was never lost — there is not one reconnect in those logs — so
// nothing was dropped in flight. The upload simply ENDED early: the handler was
// handed fewer frames than the caller had, and a clean end-of-stream after them.
//
// The mechanism is flow control. A send with no credit parks. The end-of-stream
// that follows it does NOT park — it carries no payload, so nothing meters it —
// and it overtakes the message still waiting. The peer sees a stream that
// finished, counts what arrived, and refuses the short blob. Meanwhile the
// parked sender is never woken at all, so the caller cannot even discover that
// it happened.
//
// What a sender is entitled to is narrow: either its message goes out before the
// stream ends, or it is TOLD that it did not. Silently ending a stream over a
// message that never left is the one outcome that gives the peer a truncation
// and the caller a clean conscience.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

/// The SHIPPED policy, deliberately. An artificially narrow window proves
/// something about a configuration nobody runs; the upload that failed in the
/// field ran on the defaults, at 256 KiB a frame.
const _policy = RpcSecurityPolicy();

/// One transport frame of a blob, as `ChunkedBlobIO` cuts them.
const _frameBytes = 256 * 1024;

/// A handler that is slow to start reading — the shape of the real one, which
/// streams each blob into object storage before asking for the next frame.
final class _SlowCollector extends RpcResponderContract {
  _SlowCollector({required this.startupDelay}) : super('Blob');

  final Duration startupDelay;
  final seen = <String>[];

  @override
  void setup() {
    addClientStreamMethod<RpcString, RpcString>(
      methodName: 'Upload',
      handler: (requests, {RpcContext? context}) async {
        await Future<void>.delayed(startupDelay);
        await for (final r in requests) {
          seen.add(r.value);
        }
        return RpcString('${seen.length}');
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

void main() {
  test(
    'a stream does not end while a message is still unsent',
    () async {
      final (clientT, serverT) = RpcChannelTransport.pair(policy: _policy);
      final service = _SlowCollector(startupDelay: const Duration(seconds: 2));
      final responder = RpcResponderEndpoint(transport: serverT);
      responder.registerServiceContract(service);
      responder.start();
      final caller = RpcCallerEndpoint(transport: clientT);

      // A blob the size of the ones that failed: ~3 MB, twelve frames of 256 KiB,
      // pushed at a handler that is busy writing the previous one to storage.
      const count = 12;
      final filler = 'x' * _frameBytes;
      final requests = StreamController<RpcString>();
      final answer = caller.clientStream<RpcString, RpcString>(
        serviceName: 'Blob',
        methodName: 'Upload',
        requestCodec: _codec,
        responseCodec: _codec,
      )(requests.stream);

      for (var i = 0; i < count; i++) {
        requests.add(RpcString('frame$i:$filler'));
      }
      await requests.close();

      Object? failure;
      String? value;
      try {
        value = (await answer.timeout(const Duration(seconds: 30))).value;
      } catch (e) {
        failure = e;
      }

      // The point of the test, in one sentence: a call that came back successful
      // must mean the handler got everything. The consumer's server could only
      // tell that it had not by counting bytes itself — and by then it had
      // already refused a blob the client believed it had sent.
      if (failure == null) {
        expect(
          service.seen,
          hasLength(count),
          reason:
              'the call succeeded (answer "$value") but the handler was given '
              '${service.seen.length} of $count frames — the stream ended over a '
              'message that never went out',
        );
      } else {
        // Failing is allowed. Hanging until a timeout is not: the caller has to
        // be able to find out, and a 26 MB upload that stalls forever is the
        // stall a consumer actually reported.
        expect(
          failure,
          isNot(isA<TimeoutException>()),
          reason: 'the caller was left hanging instead of being told: $failure',
        );
      }

      await caller.close();
      await responder.close();
      await clientT.close();
      await serverT.close();
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'CONTROL: the same upload is intact when the handler reads at once',
    () async {
      final (clientT, serverT) = RpcChannelTransport.pair(policy: _policy);
      final service = _SlowCollector(startupDelay: Duration.zero);
      final responder = RpcResponderEndpoint(transport: serverT);
      responder.registerServiceContract(service);
      responder.start();
      final caller = RpcCallerEndpoint(transport: clientT);

      const count = 12;
      final filler = 'x' * _frameBytes;
      final requests = StreamController<RpcString>();
      final answer = caller.clientStream<RpcString, RpcString>(
        serviceName: 'Blob',
        methodName: 'Upload',
        requestCodec: _codec,
        responseCodec: _codec,
      )(requests.stream);
      for (var i = 0; i < count; i++) {
        requests.add(RpcString('frame$i:$filler'));
      }
      await requests.close();

      expect(
        (await answer.timeout(const Duration(seconds: 30))).value,
        '$count',
      );
      expect(service.seen, hasLength(count));

      await caller.close();
      await responder.close();
      await clientT.close();
      await serverT.close();
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
