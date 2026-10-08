// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The caller refuses a response whose consumer falls past the un-consumed
// window, and HTTP/2 does not tell the server about that window. Charging
// each message a fixed overhead on top of its payload (as a fix once did)
// moved that refusal from about 470k tiny messages behind to about 30k, and
// an honest consumer only slightly slower than its server -- pausing 1 ms
// every 20 messages -- got RESOURCE_EXHAUSTED partway through a result set.

@TestOn('vm')
library;

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

const _count = 60000;

final class _Svc extends RpcResponderContract {
  _Svc() : super('Svc');

  @override
  void setup() {
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'Rows',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (request, {RpcContext? context}) async* {
        for (var i = 0; i < _count; i++) {
          yield ''.rpc;
          if (i % 2000 == 0) await Future<void>.delayed(Duration.zero);
        }
      },
    );
  }
}

void main() {
  test(
    'WITNESS a slightly slow reader receives every tiny response',
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

      var received = 0;
      final done = Completer<void>();
      late final StreamSubscription<RpcString> sub;
      sub = caller
          .serverStream<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'Rows',
            request: 'go'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .listen(
            (_) {
              received++;
              if (received % 20 == 0) {
                sub.pause(
                  Future<void>.delayed(const Duration(milliseconds: 1)),
                );
              }
            },
            onError: (Object e, StackTrace st) {
              if (!done.isCompleted) done.completeError(e, st);
            },
            onDone: () {
              if (!done.isCompleted) done.complete();
            },
          );

      await done.future.timeout(const Duration(seconds: 60));
      expect(received, _count);
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );
}
