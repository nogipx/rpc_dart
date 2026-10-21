// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// RpcWebSocketServer.dispose() releases its connections stream. Over an
// HttpServer.bind server that closes the port, and the process can exit; over
// the server bindRpcWebSocketHttpServer returns, which the README recommends
// and whose serve() example does not keep, the port stayed bound and the
// process never exited.

@TestOn('vm')
library;

import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_websocket/io.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:test/test.dart';

Future<bool> _accepting(int port) async {
  try {
    final s = await Socket.connect(
      InternetAddress.loopbackIPv4,
      port,
      timeout: const Duration(seconds: 1),
    );
    s.destroy();
    return true;
  } on SocketException {
    return false;
  }
}

Future<int> _serveAndDispose(Future<HttpServer> Function() bind) async {
  final http = await bind();
  final port = http.port; // a closed HttpServer no longer answers this
  final server = RpcWebSocketServer(
    connections: rpcWebSocketConnections(http),
    mode: RpcResponderMode((e) {}),
  );
  await server.start();
  await server.dispose();
  return port;
}

void main() {
  test('dispose releases the port of a bindRpcWebSocketHttpServer', () async {
    final port = await _serveAndDispose(
      () => bindRpcWebSocketHttpServer(InternetAddress.loopbackIPv4, 0),
    );
    expect(
      await _accepting(port),
      isFalse,
      reason: 'the port is still bound after dispose()',
    );
  });

  test('GUARD dispose releases the port of a plain HttpServer', () async {
    final port = await _serveAndDispose(
      () => HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    expect(await _accepting(port), isFalse);
  });

  test('GUARD the port serves until dispose', () async {
    final http = await bindRpcWebSocketHttpServer(
      InternetAddress.loopbackIPv4,
      0,
    );
    final server = RpcWebSocketServer(
      connections: rpcWebSocketConnections(http),
      mode: RpcResponderMode((e) {}),
    );
    await server.start();
    addTearDown(server.dispose);
    expect(await _accepting(http.port), isTrue);
  });
}
