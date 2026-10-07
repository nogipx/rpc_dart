// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A client stream that overruns the responder's un-consumed window -- the
// handler is not reading -- is refused with RESOURCE_EXHAUSTED, and the caller
// receives that status, not a synthesized one.

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
    addClientStreamMethod<RpcString, RpcString>(
      methodName: 'Ignore',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (requests, {RpcContext? context}) async {
        // Never reads the request stream.
        await Future<void>.delayed(const Duration(seconds: 30));
        return 'late'.rpc;
      },
    );
  }
}

void main() {
  test('an overrun reaches the caller as RESOURCE_EXHAUSTED', () async {
    const policy = RpcSecurityPolicy(flowControlWindowBytes: 64 * 1024);
    final server = RpcHttp2Server(
      host: '127.0.0.1',
      port: 0,
      securityPolicy: policy,
      onEndpointCreated: (e) => e.registerServiceContract(_Svc()),
    );
    await server.start();
    final transport = await RpcHttp2CallerTransport.connect(
      host: '127.0.0.1',
      port: server.port,
    );
    final caller = RpcCallerEndpoint(transport: transport);
    addTearDown(() async {
      await caller.close().catchError((Object _) {});
      await transport.close().catchError((Object _) {});
      await server.stop().catchError((Object _) {});
    });

    final chunk = 'x' * 16 * 1024;
    Object outcome;
    try {
      outcome =
          (await caller
                  .clientStream<RpcString, RpcString>(
                    serviceName: 'Svc',
                    methodName: 'Ignore',
                    requestCodec: _codec,
                    responseCodec: _codec,
                  )(
                    Stream.fromIterable([
                      for (var i = 0; i < 64; i++) chunk.rpc,
                    ]),
                  )
                  .timeout(const Duration(seconds: 15)))
              .value;
    } on RpcStatusException catch (e) {
      outcome = 'status ${e.statusCode}: ${e.message}';
    } catch (e) {
      outcome = '${e.runtimeType}: $e';
    }
    expect('$outcome', startsWith('status ${RpcStatus.resourceExhausted}'));
  });
}
