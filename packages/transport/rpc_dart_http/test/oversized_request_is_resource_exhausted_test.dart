// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A request over `maxMessageLengthBytes` came back as INVALID_ARGUMENT.
//
// The responder answered 400 for every body-read failure, and the caller's
// `_httpStatusToGrpcCode` maps 400 -> INVALID_ARGUMENT. It already maps
// 413 -> RESOURCE_EXHAUSTED, so the producing side was the only reason a peer
// was told its ARGUMENTS were malformed rather than its message too large.
//
//   before : RpcStatusException(3)  "HTTP 400 from /Svc/sink"
//   after  : RpcStatusException(8)  "HTTP 413 from /Svc/sink"
//
// It also inverted retry semantics: RpcRetryInterceptor treats
// RESOURCE_EXHAUSTED as transient and INVALID_ARGUMENT as final, so the client
// could not tell a permanent argument error from a size it might reduce.
//
// rpc_dart_http2 was given exactly this fix long ago (`_answerFramingViolation`
// argues the same case); this sibling never got it. Found by running round
// 161's battery on the one transport it had never covered.

@TestOn('vm')
library;

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http/rpc_dart_http.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

const _limit = 256 * 1024;

final class _Svc extends RpcResponderContract {
  _Svc(this._seen) : super('Svc');

  final List<int> _seen;

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'sink',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (r, {RpcContext? context}) async {
        _seen.add(r.value.length);
        return 'ok'.rpc;
      },
    );
  }
}

typedef _Rig = ({RpcCallerEndpoint caller, List<int> seen});

Future<_Rig> _serve() async {
  final seen = <int>[];
  final server = RpcHttpServer(
    host: '127.0.0.1',
    port: 0,
    securityPolicy: const RpcSecurityPolicy(maxMessageLengthBytes: _limit),
    onEndpointCreated: (e) {
      e.registerServiceContract(_Svc(seen));
      e.start();
    },
  );
  await server.start();
  await server.afterModulesStart();

  final caller = RpcCallerEndpoint(
    transport: RpcHttpCallerTransport(
      baseUrl: 'http://127.0.0.1:${server.actualPort}',
      // Generous, so the ceiling under test is the SERVER's. A shared policy
      // would make the client refuse its own request and measure nothing.
      policy: const RpcSecurityPolicy(maxMessageLengthBytes: 32 * 1024 * 1024),
    ),
  );
  addTearDown(() async {
    await caller.close();
    await server.stop();
  });
  return (caller: caller, seen: seen);
}

Future<RpcString> _send(RpcCallerEndpoint caller, int chars) =>
    caller.unaryRequest<RpcString, RpcString>(
      serviceName: 'Svc',
      methodName: 'sink',
      request: ('x' * chars).rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    );

void main() {
  test(
    'an oversized request is RESOURCE_EXHAUSTED, not INVALID_ARGUMENT',
    () async {
      // WITNESS. Pre-fix: RpcStatusException(3).
      final rig = await _serve();

      await expectLater(
        _send(rig.caller, 2 * 1024 * 1024).timeout(const Duration(seconds: 30)),
        throwsA(
          isA<RpcStatusException>().having(
            (e) => e.statusCode,
            'statusCode',
            RpcStatus.resourceExhausted,
          ),
        ),
      );
      expect(rig.seen, isEmpty, reason: 'the handler must never see it');
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'GUARD: a request inside the limit still succeeds',
    () async {
      // Without this the witnesses would pass on a server that refused
      // everything.
      final rig = await _serve();

      final response = await _send(
        rig.caller,
        1024,
      ).timeout(const Duration(seconds: 30));

      expect(response.value, 'ok');
      expect(rig.seen, [1024]);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'GUARD: an unrelated read failure is still INVALID_ARGUMENT',
    () async {
      // The status must follow the CAUSE, not become 413 for everything. A body
      // that is not a decodable gRPC frame is a malformed argument.
      final rig = await _serve();

      await expectLater(
        rig.caller
            .unaryRequest<RpcString, RpcString>(
              serviceName: 'Svc',
              methodName: 'nope',
              request: 'x'.rpc,
              requestCodec: _codec,
              responseCodec: _codec,
            )
            .timeout(const Duration(seconds: 30)),
        throwsA(
          isA<RpcStatusException>().having(
            (e) => e.statusCode,
            'statusCode',
            isNot(RpcStatus.resourceExhausted),
          ),
        ),
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
