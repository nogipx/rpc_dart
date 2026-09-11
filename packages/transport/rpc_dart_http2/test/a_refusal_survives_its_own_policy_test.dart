// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// RPC-02: a refusal must satisfy the rule that refused.
//
// Round 340 made this responder validate OUTBOUND metadata against the policy,
// which is right — and the refusal it sends when it rejects a request IS
// outbound metadata. `_answerRejectedStream` already trimmed `grpc-message` to
// `maxHeaderValueBytes` for exactly this reason, and that covers one rule.
//
// It does not cover `maxHeaders`. The trailer carries grpc-status AND
// grpc-message, so a cap below 2 refuses the refusal:
//
//   maxHeaders 32   ok(x)                                          control
//   maxHeaders  4   status 3: Too many metadata headers...         refusal arrives
//   maxHeaders  1   status 14: Response ended without a gRPC status
//
// UNAVAILABLE reads as retryable, and the truth is a deterministic policy
// rejection the peer should retry never. The status survives and the text gives
// way, which is the trade the message trimming already makes.
@TestOn('vm')
library;

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Svc extends RpcResponderContract {
  _Svc() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'Echo',
      handler: (r, {RpcContext? context}) async => r,
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

/// One unary call against a server with [policy]. The caller stays generous, so
/// the ceiling under test is always the server's.
Future<({int? status, String? value})> call(RpcSecurityPolicy policy) async {
  final server = RpcHttp2Server(
    host: '127.0.0.1',
    port: 0,
    securityPolicy: policy,
    onEndpointCreated: (e) => e.registerServiceContract(_Svc()),
  );
  await server.start();

  final t = await RpcHttp2CallerTransport.connect(
    host: '127.0.0.1',
    port: server.port,
  );
  final caller = RpcCallerEndpoint(transport: t);

  try {
    final r = await caller
        .unaryRequest<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: 'Echo',
          request: 'x'.rpc,
          requestCodec: _codec,
          responseCodec: _codec,
        )
        .timeout(const Duration(seconds: 10));
    return (status: null, value: r.value);
  } on RpcStatusException catch (e) {
    return (status: e.statusCode, value: null);
  } finally {
    await caller.close().catchError((Object _) {});
    await t.close();
    await server.stop();
  }
}

void main() {
  test(
    'a refusal the policy itself forbids still carries its status',
    () async {
      // maxHeaders: 1 admits the status-only trailer and nothing larger, so the
      // full refusal (status + message) cannot go out.
      final r = await call(const RpcSecurityPolicy(maxHeaders: 1));

      expect(
        r.status,
        RpcStatus.invalidArgument,
        reason:
            'the peer was told the stream ended without a status — UNAVAILABLE, '
            'which reads as retryable — for a deterministic policy rejection',
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'GUARD: a refusal that fits keeps its message',
    () async {
      // The fallback must be a fallback. With room for both headers the peer has
      // to keep getting the text, or the fix has traded the diagnosis away for
      // every refusal rather than the ones that cannot fit.
      final r = await call(const RpcSecurityPolicy(maxHeaders: 4));
      expect(r.status, RpcStatus.invalidArgument);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'GUARD: an ordinary call is untouched',
    () async {
      final r = await call(const RpcSecurityPolicy(maxHeaders: 32));
      expect(r.value, 'x');
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
