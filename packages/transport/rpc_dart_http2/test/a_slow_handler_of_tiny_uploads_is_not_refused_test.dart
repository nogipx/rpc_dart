// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// HTTP/2 tells a sender nothing about the per-stream request bound, so that
// bound counts payload bytes, the unit the sender's own window uses. A fixed
// per-message overhead belongs to the connection total only: charged per
// stream, it refused an honest upload of small messages to a handler only
// slightly slower than the sender, which round 715 had made legal.

@TestOn('vm')
library;

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

const _count = 20000;

final class _Svc extends RpcResponderContract {
  _Svc() : super('Svc');

  @override
  void setup() {
    addClientStreamMethod<RpcString, RpcString>(
      methodName: 'Upload',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (requests, {RpcContext? context}) async {
        var n = 0;
        await for (final _ in requests) {
          n++;
          if (n % 20 == 0) {
            await Future<void>.delayed(const Duration(milliseconds: 1));
          }
        }
        return '$n'.rpc;
      },
    );
  }
}

Stream<RpcString> _requests() async* {
  for (var i = 0; i < _count; i++) {
    yield 'x'.rpc;
    if (i % 2000 == 0) await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test(
    'WITNESS a slightly slow handler receives every tiny upload',
    () async {
      final server = RpcHttp2Server(
        host: '127.0.0.1',
        port: 0,
        // 20000 messages of 2 payload bytes are 40 KB by payload, inside this
        // bound, and 2.6 MB with a 128-byte charge each, far past it.
        securityPolicy: const RpcSecurityPolicy(maxBufferedBytes: 256 * 1024),
        onEndpointCreated: (e) => e.registerServiceContract(_Svc()),
      );
      await server.start();
      final caller = RpcCallerEndpoint(
        transport: await RpcHttp2CallerTransport.connect(
          host: '127.0.0.1',
          port: server.port,
        ),
      );
      addTearDown(() async {
        await caller.close();
        await server.stop();
      });

      final response = await caller
          .clientStream<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'Upload',
            requestCodec: _codec,
            responseCodec: _codec,
          )(_requests())
          .timeout(const Duration(seconds: 60));

      expect(response.value, '$_count');
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );
}
