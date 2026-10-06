// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Every HTTP/1.1 call is its own request. One request failing -- its socket
// dropped -- must not retire an RpcClientConnection and take the calls in
// flight on other sockets with it.

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http/rpc_dart_http.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Svc extends RpcResponderContract {
  _Svc() : super('Svc');
  @override
  void setup() {
    for (final name in ['Slow', 'Die']) {
      addUnaryMethod<RpcString, RpcString>(
        methodName: name,
        handler: (r, {RpcContext? context}) async {
          await Future<void>.delayed(const Duration(milliseconds: 500));
          return r;
        },
        requestCodec: _codec,
        responseCodec: _codec,
      );
    }
  }
}

/// Forwards to [port], destroying any connection whose request names /Svc/Die.
Future<ServerSocket> _killingProxy(int port) async {
  final proxy = await ServerSocket.bind('127.0.0.1', 0);
  proxy.listen((client) async {
    final upstream = await Socket.connect('127.0.0.1', port);
    var killed = false;
    client.listen(
      (data) {
        if (killed) return;
        if (String.fromCharCodes(data).contains('/Svc/Die')) {
          killed = true;
          client.destroy();
          upstream.destroy();
          return;
        }
        upstream.add(data);
      },
      onError: (Object _) {},
      onDone: upstream.destroy,
    );
    upstream.listen(
      (data) {
        if (!killed) client.add(data);
      },
      onError: (Object _) {},
      onDone: () {
        if (!killed) client.destroy();
      },
    );
  });
  return proxy;
}

void main() {
  test('a dropped request does not fail the calls beside it', () async {
    final server = RpcHttpServer(
      host: '127.0.0.1',
      port: 0,
      onEndpointCreated: (e) {
        e.registerServiceContract(_Svc());
        e.start();
      },
    );
    await server.start();
    await server.afterModulesStart();
    final proxy = await _killingProxy(server.actualPort!);
    final connection = RpcClientConnection(
      transportFactory: () async =>
          RpcHttpCallerTransport(baseUrl: 'http://127.0.0.1:${proxy.port}'),
    );
    addTearDown(() async {
      await connection.dispose();
      await proxy.close();
      await server.stop();
    });
    connection.connect();
    await connection.state
        .firstWhere((s) => s is RpcClientOnline)
        .timeout(const Duration(seconds: 5));
    final caller = RpcCallerEndpoint(transport: connection.transport);

    Future<String> call(String method) => caller
        .unaryRequest<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: method,
          request: 'x'.rpc,
          requestCodec: _codec,
          responseCodec: _codec,
        )
        .then(
          (_) => 'ok',
          onError: (Object e) =>
              e is RpcStatusException ? 'status ${e.statusCode}' : '$e',
        );

    final innocent = [for (var i = 0; i < 3; i++) call('Slow')];
    await Future<void>.delayed(const Duration(milliseconds: 150));

    expect(await call('Die'), 'status ${RpcStatus.unavailable}');
    expect(await Future.wait(innocent), ['ok', 'ok', 'ok']);
  });
}
