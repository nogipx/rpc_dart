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
// Follow-up: the endpoint's ping() had the same hole on its failure paths. A
// ping that reaches the wire frees its id implicitly, because it sends its
// metadata with endStream: true and the transport releases finished streams.
// But ping() allocates the id BEFORE it validates the context, so a cancelled
// token or an already-expired deadline threw straight past that release with
// nothing to free the id. Ping is the keepalive/health check, so those are the
// failure modes it actually hits — a health-check loop against a stalled
// connection burns one id per attempt until the cap is reached, and from then
// on every call on that transport fails.
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

    test('ping() frees the id when the token is already cancelled', () async {
      final (client, server) = RpcChannelTransport.pair(
        policy: const RpcSecurityPolicy(maxActiveStreams: 1),
      );

      final caller = RpcCallerEndpoint(transport: client);
      final responder = RpcResponderEndpoint(transport: server);
      responder.start();

      final token = RpcCancellationToken();
      token.cancel('stop');

      // Throws after createStream() but before anything is sent, so the
      // transport never sees the endStream that would free the id.
      await expectLater(
        caller.ping(context: RpcContext.withCancellation(token)),
        throwsA(isA<RpcCancelledException>()),
      );

      // The failed ping must not have consumed the only available id.
      await expectLater(
        caller.ping(timeout: const Duration(seconds: 5)),
        completes,
      );

      await caller.close();
      await responder.close();
      await client.close();
      await server.close();
    });

    test('ping() frees the id when the deadline is already expired', () async {
      final (client, server) = RpcChannelTransport.pair(
        policy: const RpcSecurityPolicy(maxActiveStreams: 1),
      );

      final caller = RpcCallerEndpoint(transport: client);
      final responder = RpcResponderEndpoint(transport: server);
      responder.start();

      // Throws after createStream() but before anything is sent.
      await expectLater(
        caller.ping(
          context: RpcContext.withDeadline(
            DateTime.fromMillisecondsSinceEpoch(0),
          ),
        ),
        throwsA(isA<RpcDeadlineExceededException>()),
      );

      // The failed ping must not have consumed the only available id.
      await expectLater(
        caller.ping(timeout: const Duration(seconds: 5)),
        completes,
      );

      await caller.close();
      await responder.close();
      await client.close();
      await server.close();
    });
  });
}
