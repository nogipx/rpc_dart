// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// permessage-deflate is an unbounded decompression bomb on the SERVER side:
// dart:io inflates each incoming message with RawZLibFilter and no output limit,
// BEFORE rpc_dart's maxMessageLengthBytes can see it. Measured through a
// byte-counting relay:
//
//   compression ON  : attacker uploads 0.25 MiB -> 516 MiB server RSS  (2071x)
//   compression OFF : attacker must upload 256 MiB -> 682 MiB          (2.7x)
//
// So rpcWebSocketConnections defaults compression OFF. dart:io exposes no output
// bound, so whether to negotiate the extension at all is the only lever.
//
// The deterministic witness is the HANDSHAKE: with compression off the server's
// 101 response must NOT contain a permessage-deflate `Sec-WebSocket-Extensions`
// header, even when the client offers it. No RSS, no bomb -- the negotiation
// header is the exact thing the fix controls.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_websocket/io.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:test/test.dart';

/// Performs a raw WebSocket upgrade offering permessage-deflate and returns the
/// server's 101 response headers, lower-cased.
Future<Map<String, String>> upgradeOfferingDeflate(int port) async {
  final socket = await Socket.connect('127.0.0.1', port);
  // A fixed, valid Sec-WebSocket-Key (base64 of 16 bytes); the value does not
  // matter to this test, only that the request is a well-formed upgrade that
  // offers permessage-deflate.
  socket.write(
    'GET / HTTP/1.1\r\n'
    'Host: 127.0.0.1:$port\r\n'
    'Upgrade: websocket\r\n'
    'Connection: Upgrade\r\n'
    'Sec-WebSocket-Version: 13\r\n'
    'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n'
    'Sec-WebSocket-Extensions: permessage-deflate\r\n'
    '\r\n',
  );

  final buf = StringBuffer();
  final done = Completer<void>();
  late StreamSubscription<List<int>> sub;
  sub = socket.listen(
    (chunk) {
      buf.write(latin1.decode(chunk));
      if (buf.toString().contains('\r\n\r\n') && !done.isCompleted) {
        done.complete();
      }
    },
    onError: (Object _) {
      if (!done.isCompleted) done.complete();
    },
    cancelOnError: false,
  );

  await done.future.timeout(const Duration(seconds: 5), onTimeout: () {});
  await sub.cancel();
  socket.destroy();

  final headers = <String, String>{};
  for (final line in buf.toString().split('\r\n')) {
    final idx = line.indexOf(':');
    if (idx > 0) {
      headers[line.substring(0, idx).trim().toLowerCase()] = line
          .substring(idx + 1)
          .trim();
    }
  }
  return headers;
}

void main() {
  late HttpServer http;
  late RpcWebSocketServer server;

  tearDown(() async {
    await server.stop().catchError((Object _) {});
    await http.close(force: true);
  });

  test(
    'the server does not negotiate permessage-deflate by default',
    () async {
      http = await HttpServer.bind('127.0.0.1', 0);
      server = RpcWebSocketServer(
        connections: rpcWebSocketConnections(http),
        onEndpointCreated: (e) {},
      );
      await server.start();

      final headers = await upgradeOfferingDeflate(http.port);

      // The upgrade still succeeds...
      expect(
        headers['upgrade']?.toLowerCase(),
        'websocket',
        reason: 'the handshake must still complete, just without compression',
      );
      // ...but permessage-deflate must NOT be accepted, or dart:io would inflate
      // incoming messages unbounded.
      expect(
        headers['sec-websocket-extensions'],
        anyOf(isNull, isNot(contains('permessage-deflate'))),
        reason:
            'the server negotiated permessage-deflate, re-opening the '
            'decompression-bomb: a few hundred KiB on the wire inflates to '
            'hundreds of MiB of RSS before any rpc_dart limit can see it',
      );
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'GUARD: opting compression back in negotiates it',
    () async {
      // Proves the parameter still works for peers you control, and that the
      // witness above is really keyed on the negotiation rather than always
      // absent.
      http = await HttpServer.bind('127.0.0.1', 0);
      server = RpcWebSocketServer(
        connections: rpcWebSocketConnections(
          http,
          compression: CompressionOptions.compressionDefault,
        ),
        onEndpointCreated: (e) {},
      );
      await server.start();

      final headers = await upgradeOfferingDeflate(http.port);
      expect(
        headers['sec-websocket-extensions'],
        contains('permessage-deflate'),
        reason: 'an explicit opt-in must still enable compression',
      );
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'GUARD: an ordinary RPC call works with compression off',
    () async {
      final codec = RpcCodec(RpcString.fromJson);
      http = await HttpServer.bind('127.0.0.1', 0);
      server = RpcWebSocketServer(
        connections: rpcWebSocketConnections(http),
        onEndpointCreated: (e) => e.registerServiceContract(_EchoContract()),
      );
      await server.start();

      final transport = await RpcWebSocketCallerTransport.connect(
        Uri.parse('ws://127.0.0.1:${http.port}'),
      );
      final caller = RpcCallerEndpoint(transport: transport);
      addTearDown(() async {
        await caller.close().catchError((Object _) {});
        await transport.close().catchError((Object _) {});
      });

      final r = await caller
          .unaryRequest<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'Echo',
            request: 'ping'.rpc,
            requestCodec: codec,
            responseCodec: codec,
          )
          .timeout(const Duration(seconds: 8));
      expect(r.value, 'echo-ping');
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}

final class _EchoContract extends RpcResponderContract {
  _EchoContract() : super('Svc');

  static final _codec = RpcCodec(RpcString.fromJson);

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'Echo',
      handler: (request, {RpcContext? context}) async =>
          'echo-${request.value}'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}
