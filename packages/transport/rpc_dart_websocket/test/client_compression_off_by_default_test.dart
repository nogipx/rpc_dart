// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The CALLER half of the permessage-deflate bomb.
//
// The server default was closed last round. But the CLIENT
// (IOWebSocketChannel.connect, used by RpcWebSocketCallerTransport.connect)
// passed no compression argument, so it used dart:io's default (ON) and OFFERED
// permessage-deflate -- letting a hostile or compromised server negotiate it
// and flood the client, which dart:io inflates with no output bound before
// rpc_dart sees the message.
//
// Measured against a server answering a 256 MiB payload of zeros, isolated in a
// subprocess with a byte-counting relay:
//
//   offering it     : 0.25 MiB on the wire -> 248 MiB client RSS   (995x)
//   not offering it : the server cannot compress; 256 MiB uploaded  (3.1x)
//
// So the client no longer offers the extension by default. The deterministic
// witness is the upgrade REQUEST: with compression off it must not carry a
// `permessage-deflate` Sec-WebSocket-Extensions header. No RSS, no bomb -- the
// offer is exactly what the fix controls.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_websocket/io.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:test/test.dart';

void main() {
  late HttpServer http;
  WebSocket? serverSide;

  tearDown(() async {
    await serverSide?.close().catchError((Object _) {});
    await http.close(force: true);
  });

  /// Binds a server that records the client's offered Sec-WebSocket-Extensions
  /// and completes the handshake, then connects [connect] to it.
  Future<String?> offeredExtensionsFor(
    Future<RpcWebSocketCallerTransport> Function(Uri uri) connect,
  ) async {
    http = await HttpServer.bind('127.0.0.1', 0);
    final offered = Completer<String?>();
    http.listen((req) async {
      if (!offered.isCompleted) {
        offered.complete(req.headers.value('sec-websocket-extensions'));
      }
      serverSide = await WebSocketTransformer.upgrade(
        req,
        compression: CompressionOptions.compressionOff,
      );
    });

    final transport = await connect(
      Uri.parse('ws://127.0.0.1:${http.port}'),
    ).timeout(const Duration(seconds: 8));
    addTearDown(() => transport.close().catchError((Object _) {}));

    return offered.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () => null,
    );
  }

  test(
    'the client does not offer permessage-deflate by default',
    () async {
      final offered = await offeredExtensionsFor(
        (uri) => RpcWebSocketCallerTransport.connect(uri),
      );
      expect(
        offered ?? '',
        isNot(contains('permessage-deflate')),
        reason:
            'the client offered permessage-deflate, so a hostile server could '
            'negotiate it and flood the client: a few hundred KiB on the wire '
            'inflates to hundreds of MiB of RSS before any rpc_dart limit sees it',
      );
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'GUARD: opting compression back in offers it',
    () async {
      // Proves the parameter still works against servers you control, and that
      // the witness is really keyed on the offer rather than always absent.
      final offered = await offeredExtensionsFor(
        (uri) =>
            RpcWebSocketCallerTransport.connect(uri, enableCompression: true),
      );
      expect(offered ?? '', contains('permessage-deflate'));
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'GUARD: an ordinary RPC call works with client compression off',
    () async {
      final codec = RpcCodec(RpcString.fromJson);
      http = await HttpServer.bind('127.0.0.1', 0);
      final server = RpcWebSocketServer(
        connections: rpcWebSocketConnections(http),
        onEndpointCreated: (e) => e.registerServiceContract(_EchoContract()),
      );
      await server.start();
      addTearDown(() => server.stop().catchError((Object _) {}));

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
