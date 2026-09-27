// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Both HTTP/1.1 body bounds measured the raw HTTP body against
// `maxMessageLengthBytes`. That body IS the gRPC-framed message, so it carries the
// 5-byte prefix the message limit does not count — making the real ceiling
// `maxMessageLengthBytes - 5` and rejecting a message at exactly the configured
// limit. `RpcFrameMultiplexedChannel` has a comment saying precisely that, and it
// is why the channel transports add the prefix.
//
// Measured with the limit set to one message's EXACT serialized length, so
// "exactly at the limit" needs no arithmetic about the codec:
//
//   channel transport   ACCEPTED
//   HTTP/1.1            REFUSED, RESOURCE_EXHAUSTED
//   both, limit + 5     ACCEPTED        <- so it is the five bytes
//
// The rule now has ONE home, `RpcSecurityPolicy.maxFramedMessageBytes`, which the
// frame channel also uses; it was computed inline in three places before.
@TestOn('vm')
library;

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http/rpc_dart_http.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _EchoService extends RpcResponderContract {
  _EchoService() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'Echo',
      handler: (request, {RpcContext? context}) async =>
          '${request.value.length}'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

void main() {
  /// One unary call over HTTP/1.1 under [policy]. Returns `'ok'` or the status.
  Future<String> call(RpcSecurityPolicy policy, RpcString message) async {
    final server = RpcHttpServer(
      host: '127.0.0.1',
      port: 0,
      securityPolicy: policy,
      onEndpointCreated: (e) {
        e.registerServiceContract(_EchoService());
        e.start();
      },
    );
    await server.start();
    await server.afterModulesStart();
    final transport = RpcHttpCallerTransport(
      baseUrl: 'http://127.0.0.1:${server.actualPort!}',
      policy: policy,
    );
    final caller = RpcCallerEndpoint(transport: transport);
    addTearDown(() async {
      await caller.close().catchError((Object _) {});
      await transport.close().catchError((Object _) {});
      await server.stop();
    });

    try {
      await caller
          .unaryRequest<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'Echo',
            request: message,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .timeout(const Duration(seconds: 10));
      return 'ok';
    } on RpcStatusException catch (e) {
      return 'status=${e.statusCode}';
    }
  }

  final message = ('x' * 1000).rpc;
  // The limit IS this message's serialized length, so the test never has to
  // predict what CBOR does to a 1000-character string.
  final exact = _codec.serialize(message).length;

  // WITNESS. Before the fix this was status=8: the framed body is `exact + 5`,
  // which the old check compared against `exact`.
  test(
    'a message at exactly maxMessageLengthBytes is accepted',
    () async {
      expect(
        await call(RpcSecurityPolicy(maxMessageLengthBytes: exact), message),
        'ok',
        reason:
            'the limit is in MESSAGE bytes and the body carries the 5-byte gRPC '
            'prefix; comparing the framed length against it makes the real '
            'ceiling max - 5',
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  // CONTROL. With room for the prefix it always worked, so the witness is the
  // five bytes and not the message being large.
  test(
    'CONTROL: the same message under limit + 5 is accepted',
    () async {
      expect(
        await call(
          RpcSecurityPolicy(maxMessageLengthBytes: exact + 5),
          message,
        ),
        'ok',
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  // GUARD, and load-bearing: widening a bound by five bytes is exactly the change
  // that can remove it. One byte of message over must still be refused.
  test(
    'GUARD: one byte over the limit is still refused',
    () async {
      expect(
        await call(
          RpcSecurityPolicy(maxMessageLengthBytes: exact - 1),
          message,
        ),
        'status=${RpcStatus.resourceExhausted}',
        reason: 'a bound that refuses nothing is not a bound',
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
