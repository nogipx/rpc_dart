// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Audit finding (core audit, round 2): client-side stream ids leaked.
//
// CallProcessor and UnaryCaller allocate a transport stream id via
// createStream() (which counts against maxActiveStreams), but:
//  - CallProcessor.close() only closed its scope and never released the id, so
//    any call closed WITHOUT a clean finishSending (cancellation, deadline,
//    error) leaked its slot;
//  - CallProcessor's constructor allocates the id in the initializer, then the
//    body can throw (bad codecs, already-expired deadline) before an instance
//    exists, leaking the id with no close() to ever run;
//  - UnaryCaller never released the id at all.
//
// With the default maxActiveStreams the leak eventually throws
// "Too many active streams". These tests use a cap of 1 so a single leak is
// observable immediately.

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

void main() {
  final codec = RpcCodec(RpcString.fromJson);

  group('client stream-id is released', () {
    test('CallProcessor.close() frees the id (no leak across calls)', () async {
      final (client, server) = RpcChannelTransport.pair(
        policy: const RpcSecurityPolicy(maxActiveStreams: 1),
      );

      final p1 = CallProcessor<RpcString, RpcString>(
        transport: client,
        serviceName: 'S',
        methodName: 'M',
        requestCodec: codec,
        responseCodec: codec,
      );
      await p1.close();

      // If close() leaked the id, this second allocation throws StateError
      // ("Too many active streams") under the cap of 1.
      late final CallProcessor<RpcString, RpcString> p2;
      expect(() {
        p2 = CallProcessor<RpcString, RpcString>(
          transport: client,
          serviceName: 'S',
          methodName: 'M',
          requestCodec: codec,
          responseCodec: codec,
        );
      }, returnsNormally);
      await p2.close();

      await client.close();
      await server.close();
    });

    test('CallProcessor releases the id when the constructor throws', () {
      final (client, server) = RpcChannelTransport.pair(
        policy: const RpcSecurityPolicy(maxActiveStreams: 1),
      );

      // An already-expired deadline makes _checkContextBeforeCall() throw after
      // createStream() ran in the initializer.
      expect(
        () => CallProcessor<RpcString, RpcString>(
          transport: client,
          serviceName: 'S',
          methodName: 'M',
          requestCodec: codec,
          responseCodec: codec,
          context: RpcContext.withDeadline(
            DateTime.fromMillisecondsSinceEpoch(0),
          ),
        ),
        throwsA(isA<RpcDeadlineExceededException>()),
      );

      // The failed construction must not have leaked the only available id.
      late final CallProcessor<RpcString, RpcString> p;
      expect(() {
        p = CallProcessor<RpcString, RpcString>(
          transport: client,
          serviceName: 'S',
          methodName: 'M',
          requestCodec: codec,
          responseCodec: codec,
        );
      }, returnsNormally);

      p.close();
      client.close();
      server.close();
    });

    test('UnaryCaller releases the id after a failed/timed-out call', () async {
      final (client, server) = RpcChannelTransport.pair(
        policy: const RpcSecurityPolicy(maxActiveStreams: 1),
      );

      // No server responder is bound, so the call times out; the id must be
      // released in the finally block.
      final caller1 = UnaryCaller<RpcString, RpcString>(
        transport: client,
        serviceName: 'S',
        methodName: 'M',
        requestCodec: codec,
        responseCodec: codec,
      );
      await expectLater(
        caller1.call('x'.rpc, timeout: const Duration(milliseconds: 50)),
        throwsA(anything),
      );

      // A second unary call must be able to allocate the (now-released) id.
      final caller2 = UnaryCaller<RpcString, RpcString>(
        transport: client,
        serviceName: 'S',
        methodName: 'M',
        requestCodec: codec,
        responseCodec: codec,
      );
      await expectLater(
        caller2.call('y'.rpc, timeout: const Duration(milliseconds: 50)),
        throwsA(anything),
      );

      await client.close();
      await server.close();
    });
  });
}
