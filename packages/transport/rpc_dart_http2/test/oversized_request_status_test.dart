// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A request larger than RpcSecurityPolicy.maxMessageLengthBytes WAS rejected --
// the limit worked -- but the peer was told the wrong thing. The parse failure
// was reported to our own side via _emitStreamError and nothing else: the
// offending frame is dropped, so the stream reached the responder pipeline
// carrying no payload, and the peer got whatever the pipeline made of an empty
// request.
//
// Measured against grpcurl -- a real gRPC client -- with
// maxMessageLengthBytes: 4096 and a 20KB request:
//
//   before: Code: InvalidArgument
//           Message: Request stream closed without payload for
//                    shapes.v1.ShapeService.Unary
//   after : Code: ResourceExhausted
//           Message: RpcException: gRPC frame buffer overflow: 16384 bytes
//                    (max: 4101)
//
// Both halves were wrong. gRPC answers an over-limit message with
// RESOURCE_EXHAUSTED (grpc-go and grpc-java both do), and INVALID_ARGUMENT
// tells the caller its ARGUMENTS were malformed rather than too large -- which
// also inverts retry semantics, since rpc_dart's own RpcRetryInterceptor
// treats RESOURCE_EXHAUSTED as transient and INVALID_ARGUMENT as final. The
// old message named a symptom (no payload arrived), not the cause.
//
// The boundary is the policy value: 4000 bytes round-tripped, 4200 did not.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

const _limit = 4096;

final class _Svc extends RpcResponderContract {
  _Svc() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'echo',
      handler: (r, {RpcContext? context}) async => 'ok:${r.value.length}'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

void main() {
  late RpcHttp2Server server;
  late RpcHttp2CallerTransport clientTransport;
  late RpcCallerEndpoint caller;

  setUp(() async {
    server = RpcHttp2Server(
      host: '127.0.0.1',
      port: 0,
      securityPolicy: const RpcSecurityPolicy(maxMessageLengthBytes: _limit),
      onEndpointCreated: (endpoint) {
        endpoint.registerServiceContract(_Svc());
      },
    );
    await server.start();

    clientTransport = await RpcHttp2CallerTransport.connect(
      host: '127.0.0.1',
      port: server.port,
      logger: LogScope.noop,
    );
    caller = RpcCallerEndpoint(transport: clientTransport);
  });

  tearDown(() async {
    await caller.close();
    await server.stop();
  });

  Future<Object?> send(int chars) async {
    try {
      await caller
          .unaryRequest<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'echo',
            request: ('A' * chars).rpc,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .timeout(const Duration(seconds: 10));
      return null;
    } catch (e) {
      return e;
    }
  }

  group('a request over the size limit', () {
    // WITNESS: this was InvalidArgument.
    test('is refused with RESOURCE_EXHAUSTED', () async {
      final error = await send(20000);

      expect(error, isA<RpcStatusException>());
      final status = error! as RpcStatusException;
      expect(
        status.statusCode,
        RpcStatus.resourceExhausted,
        reason:
            'an over-limit message came back as ${status.statusCode} '
            '("${status.message}"); gRPC answers this with RESOURCE_EXHAUSTED, '
            'and the code drives retry behaviour',
      );
    });

    // WITNESS: the message named a symptom, not the cause.
    test('names the limit rather than a missing payload', () async {
      final error = await send(20000);
      final status = error! as RpcStatusException;

      expect(
        status.message,
        anyOf(contains('too large'), contains('overflow')),
        reason: 'the message should say what was exceeded: "${status.message}"',
      );
      expect(
        status.message,
        isNot(contains('without payload')),
        reason: 'that wording described the symptom of dropping the frame',
      );
    });
  });

  group('the limit boundary is unchanged', () {
    // GUARDS: pass on both sides. The fix must not alter what is accepted.
    test('a request under the limit still round-trips', () async {
      final error = await send(1000);
      expect(error, isNull, reason: 'a 1000-byte request was refused: $error');
    });

    test('the connection survives a refused request', () async {
      final refused = await send(20000);
      expect(refused, isA<RpcStatusException>());

      // The next call on the SAME connection must still work: refusing one
      // message must not poison the channel.
      final ok = await send(500);
      expect(
        ok,
        isNull,
        reason: 'the connection stopped working after a refusal: $ok',
      );
    });
  });
}
