// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The caller's close() aborts its active calls at once: it does not sit out a
// grace period first, and the call it aborts fails with a status.

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
      methodName: 'Slow',
      handler: (r, {RpcContext? context}) async {
        await Future<void>.delayed(const Duration(seconds: 5));
        return r;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

void main() {
  test(
    'close() with a call in flight returns without a grace period',
    () async {
      final server = RpcHttp2Server(
        host: '127.0.0.1',
        port: 0,
        onEndpointCreated: (e) => e.registerServiceContract(_Svc()),
      );
      await server.start();
      addTearDown(() => server.stop().catchError((Object _) {}));
      final transport = await RpcHttp2CallerTransport.connect(
        host: '127.0.0.1',
        port: server.port,
      );
      final caller = RpcCallerEndpoint(transport: transport);

      final call = caller
          .unaryRequest<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'Slow',
            request: 'x'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .then<Object>((r) => r.value, onError: (Object e) => e);
      await Future<void>.delayed(const Duration(milliseconds: 200));

      final clock = Stopwatch()..start();
      await transport.close();
      final closeMs = clock.elapsedMilliseconds;

      final outcome = await call.timeout(const Duration(seconds: 3));
      await caller.close().catchError((Object _) {});

      expect(outcome, isA<RpcException>(), reason: '$outcome');
      expect(closeMs, lessThan(50), reason: 'close() took ${closeMs}ms');
    },
  );
}
