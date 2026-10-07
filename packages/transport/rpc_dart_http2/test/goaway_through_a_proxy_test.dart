// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// GOAWAY reaches the caller the same way through an HTTP CONNECT proxy as on a
// direct connection: a call after it is UNAVAILABLE -- retryable, "go
// elsewhere" -- and health() stops reporting the connection healthy.
// goaway_is_unavailable_test.dart is the direct-path twin.

@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:http2/http2.dart' as http2;
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

void _answerOk(http2.ServerTransportStream stream) {
  stream.sendHeaders([
    http2.Header.ascii(':status', '200'),
    http2.Header.ascii('content-type', 'application/grpc+proto'),
  ]);
  stream.sendData(
    RpcMessageFrame.encode(_codec.serialize('ok'.rpc), compressed: false),
  );
  stream.sendHeaders([http2.Header.ascii('grpc-status', '0')], endStream: true);
}

/// A CONNECT proxy that tunnels to [targetPort] on loopback.
Future<ServerSocket> _proxy(int targetPort) async {
  final proxy = await ServerSocket.bind('127.0.0.1', 0);
  proxy.listen((client) async {
    final head = <int>[];
    late StreamSubscription<List<int>> sub;
    Socket? upstream;
    sub = client.listen(
      (data) async {
        if (upstream != null) {
          upstream!.add(data);
          return;
        }
        head.addAll(data);
        final text = String.fromCharCodes(head);
        final end = text.indexOf('\r\n\r\n');
        if (end < 0) return;
        sub.pause();
        upstream = await Socket.connect('127.0.0.1', targetPort);
        client.add('HTTP/1.1 200 Connection established\r\n\r\n'.codeUnits);
        final rest = head.sublist(end + 4);
        if (rest.isNotEmpty) upstream!.add(rest);
        upstream!.listen(
          client.add,
          onDone: () => client.destroy(),
          onError: (Object _) => client.destroy(),
        );
        sub.resume();
      },
      onDone: () => upstream?.destroy(),
      onError: (Object _) => upstream?.destroy(),
    );
  });
  return proxy;
}

void main() {
  late ServerSocket server;
  late ServerSocket proxy;
  late RpcHttp2CallerTransport transport;
  http2.ServerTransportConnection? live;

  setUp(() async {
    server = await ServerSocket.bind('127.0.0.1', 0);
    server.listen((client) {
      final conn = http2.ServerTransportConnection.viaSocket(client);
      live = conn;
      conn.incomingStreams.listen((stream) {
        var hold = false;
        stream.incomingMessages.listen((m) {
          if (m is http2.HeadersStreamMessage &&
              m.headers.any(
                (h) =>
                    String.fromCharCodes(h.name) == ':path' &&
                    String.fromCharCodes(h.value).endsWith('/Hold'),
              )) {
            hold = true;
          }
        }, onError: (Object _) {});
        // Answered later: the call that keeps the connection open, draining,
        // after GOAWAY.
        Future<void>.delayed(
          Duration(milliseconds: 1),
          () => hold
              ? Future<void>.delayed(
                  const Duration(seconds: 4),
                  () => _answerOk(stream),
                )
              : _answerOk(stream),
        );
      }, onError: (Object _) {});
    }, onError: (Object _) {});
    proxy = await _proxy(server.port);

    transport = await RpcHttp2CallerTransport.connect(
      host: '127.0.0.1',
      port: server.port,
      proxyUri: Uri.parse('http://127.0.0.1:${proxy.port}'),
    );
  });

  tearDown(() async {
    await transport.close().catchError((Object _) {});
    await proxy.close();
    await server.close();
  });

  Future<Object?> callAndCatch(
    RpcCallerEndpoint caller, {
    String method = 'Echo',
  }) async {
    try {
      await caller
          .unaryRequest<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: method,
            request: 'x'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .timeout(const Duration(seconds: 8));
      return null;
    } catch (e) {
      return e;
    }
  }

  /// GOAWAY while [caller] has a call in flight, so the connection stays open,
  /// draining, instead of closing at once.
  Future<void> drain(RpcCallerEndpoint caller) async {
    unawaited(callAndCatch(caller, method: 'Hold'));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    unawaited(live!.finish().catchError((Object _) {}));
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }

  test('through a proxy, a call after GOAWAY is UNAVAILABLE', () async {
    final caller = RpcCallerEndpoint(transport: transport);
    addTearDown(() => caller.close().catchError((Object _) {}));

    expect(await callAndCatch(caller), isNull, reason: 'the tunnel works');
    await drain(caller);

    final error = await callAndCatch(caller);
    expect(error, isA<RpcStatusException>());
    expect((error as RpcStatusException).statusCode, RpcStatus.unavailable);
  });

  test('through a proxy, health stops reporting healthy', () async {
    final caller = RpcCallerEndpoint(transport: transport);
    addTearDown(() => caller.close().catchError((Object _) {}));
    expect(await callAndCatch(caller), isNull);

    expect((await transport.health()).level, RpcHealthLevel.healthy);
    await drain(caller);
    expect((await transport.health()).level, isNot(RpcHealthLevel.healthy));
  });
}
