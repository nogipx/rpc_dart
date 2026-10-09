// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The un-consumed bound counted the message that had just arrived. A message
// is delivered whole, so every message larger than the window -- 4 MiB by
// default, against a 16 MiB message limit -- was refused with
// RESOURCE_EXHAUSTED in both directions, from a peer reading as fast as it
// could.

@TestOn('vm')
library;

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);
const _size = 6 * 1000 * 1000;

final class _Svc extends RpcResponderContract {
  _Svc() : super('Svc');

  @override
  void setup() {
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'feed',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (request, {RpcContext? context}) async* {
        final body = 'x' * _size;
        for (var i = 0; i < 3; i++) {
          yield body.rpc;
        }
      },
    );
    addClientStreamMethod<RpcString, RpcString>(
      methodName: 'upload',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (requests, {RpcContext? context}) async {
        var n = 0;
        await for (final _ in requests) {
          n++;
        }
        return '$n'.rpc;
      },
    );
  }
}

Stream<RpcString> _uploads() async* {
  final body = 'x' * _size;
  for (var i = 0; i < 3; i++) {
    yield body.rpc;
  }
}

void main() {
  late RpcHttp2Server server;
  late RpcCallerEndpoint caller;

  setUp(() async {
    server = RpcHttp2Server(
      host: '127.0.0.1',
      port: 0,
      onEndpointCreated: (e) => e.registerServiceContract(_Svc()),
    );
    await server.start();
    caller = RpcCallerEndpoint(
      transport: await RpcHttp2CallerTransport.connect(
        host: '127.0.0.1',
        port: server.port,
      ),
    );
  });

  tearDown(() async {
    await caller.close();
    await server.stop();
  });

  test(
    'WITNESS response messages larger than the window arrive',
    () async {
      final got = await caller
          .serverStream<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'feed',
            requestCodec: _codec,
            responseCodec: _codec,
            request: ''.rpc,
          )
          .length
          .timeout(const Duration(seconds: 30));
      expect(got, 3);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'WITNESS request messages larger than the window arrive',
    () async {
      final answer = await caller
          .clientStream<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'upload',
            requestCodec: _codec,
            responseCodec: _codec,
          )(_uploads())
          .timeout(const Duration(seconds: 30));
      expect(answer.value, '3');
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
