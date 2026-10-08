// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// HTTP/2 carries no message credit, and the responder keeps reading so its own
// byte window does not throttle the sender. The responder's depth bound
// (`maxBufferedMessagesPerStream`) therefore failed any client-stream or bidi
// call more than that many SMALL messages ahead of its handler, from a peer
// doing nothing wrong: a real gRPC client streaming 8-byte messages to a
// handler that pauses 1 ms every 20 failed at about 8200.
//
// The h2 responder declares IRpcNoMessageCredit, so its request queues are
// bounded by bytes alone, the bound this transport already enforces.

@TestOn('vm')
library;

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

const _count = 30000;

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
    'WITNESS small uploads reach a slightly slow handler',
    () async {
      final server = RpcHttp2Server(
        host: '127.0.0.1',
        port: 0,
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
