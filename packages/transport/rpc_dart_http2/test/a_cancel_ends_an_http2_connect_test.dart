// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A cancellation token ends an http2 connect in whatever stage it waits --
// the TLS handshake, a proxy's CONNECT answer -- and closes its socket at
// once. Without one, RpcClientConnection.dispose() left the socket open until
// the transport's own 30 s connectTimeout. A cancel after the connect has
// delivered leaves the connection alone.

@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

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

/// A listener that accepts TCP and never writes, and when its first
/// connection was closed by the client.
Future<({int port, Future<void> closed})> _silentListener() async {
  final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final held = <Socket>[];
  final accepted = Completer<void>();
  final closed = Completer<void>();
  listener.listen((s) {
    held.add(s);
    if (!accepted.isCompleted) accepted.complete();
    s.listen(
      (_) {},
      onDone: () {
        if (!closed.isCompleted) closed.complete();
      },
      onError: (Object _) {
        if (!closed.isCompleted) closed.complete();
      },
    );
  });
  addTearDown(() async {
    for (final s in held) {
      s.destroy();
    }
    await listener.close();
  });
  return (
    port: listener.port,
    closed: accepted.future.then((_) => closed.future),
  );
}

void main() {
  for (final stage in ['TLS handshake', 'proxy CONNECT']) {
    test(
      'a cancel during the $stage ends the connect and its socket',
      () async {
        final peer = await _silentListener();
        final token = RpcCancellationToken();
        final connect = stage == 'TLS handshake'
            ? RpcHttp2CallerTransport.secureConnect(
                host: '127.0.0.1',
                port: peer.port,
                cancellationToken: token,
              )
            : RpcHttp2CallerTransport.connect(
                host: 'example.invalid',
                proxyUri: Uri.parse('http://127.0.0.1:${peer.port}'),
                cancellationToken: token,
              );
        await Future<void>.delayed(const Duration(milliseconds: 200));
        token.cancel('dispose');
        await expectLater(
          connect.timeout(
            const Duration(seconds: 5),
            onTimeout: () =>
                fail('the connect is still pending 5 s after the cancel'),
          ),
          throwsA(isA<RpcCancelledException>()),
        );
        await peer.closed.timeout(
          const Duration(seconds: 5),
          onTimeout: () =>
              fail('the socket is still open 5 s after the cancel'),
        );
      },
    );
  }

  test('a cancel after the connect leaves the connection working', () async {
    final server = RpcHttp2Server(
      host: '127.0.0.1',
      port: 0,
      mode: RpcResponderMode((e) => e.registerServiceContract(_Svc())),
    );
    await server.start();
    addTearDown(server.stop);
    final token = RpcCancellationToken();
    final transport = await RpcHttp2CallerTransport.connect(
      host: '127.0.0.1',
      port: server.port,
      cancellationToken: token,
    );
    final caller = RpcCallerEndpoint(transport: transport);
    addTearDown(() async {
      await caller.close();
      await transport.close();
    });
    Future<String> echo() async => (await caller.unary<RpcString, RpcString>(
      serviceName: 'Svc',
      methodName: 'Echo',
      request: 'up'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    )).value;

    expect(await echo(), 'up');
    token.cancel('too late');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(await echo().timeout(const Duration(seconds: 5)), 'up');
  });
}
