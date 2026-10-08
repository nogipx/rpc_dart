// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The caller bounds a response its consumer has stopped reading by the
// un-consumed window. Charged payload bytes alone, a server streaming 9-byte
// messages got 472k of them into a paused caller, 108 MiB held against a
// 4 MiB window. Each message now also counts what it retains.

@TestOn('vm')
library;

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

const _count = 300000;
var _produced = 0;

final class _Svc extends RpcResponderContract {
  _Svc() : super('Svc');

  @override
  void setup() {
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'Flood',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (request, {RpcContext? context}) async* {
        for (var i = 0; i < _count; i++) {
          _produced++;
          yield ''.rpc;
          if (i % 2000 == 0) await Future<void>.delayed(Duration.zero);
        }
      },
    );
  }
}

void main() {
  test(
    'WITNESS a paused caller stops a flood of tiny responses',
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
      final sub = caller
          .serverStream<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'Flood',
            request: 'go'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .listen((_) => received++, onError: (Object _) {});
      addTearDown(sub.cancel);
      while (received < 3) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      sub.pause();

      // Until the server stops producing.
      var last = -1;
      while (_produced != last) {
        last = _produced;
        await Future<void>.delayed(const Duration(seconds: 1));
      }

      expect(
        _produced,
        lessThan(100000),
        reason: 'the paused caller kept taking tiny responses past its window',
      );
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );
}
