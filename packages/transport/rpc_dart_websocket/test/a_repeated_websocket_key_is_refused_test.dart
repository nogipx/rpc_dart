// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// dart:io's `WebSocketTransformer.isUpgradeRequest` reads headers with
// `value()`, which THROWS on a repeated header. A request carrying two
// Sec-WebSocket-Key headers made the upgrade filter throw; with compression on
// that error reached dart:io's own transformer, which has no error handler, and
// the process died -- one unauthenticated request.

@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_websocket/io.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Echo extends RpcResponderContract {
  _Echo() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'echo',
      handler: (r, {RpcContext? context}) async => r,
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

/// Sends an upgrade request with two Sec-WebSocket-Key headers and returns
/// the status line the server answers with.
Future<String> _twoKeys(int port) async {
  final socket = await Socket.connect('127.0.0.1', port);
  final answer = StringBuffer();
  final done = Completer<void>();
  socket.listen(
    (data) => answer.write(latin1.decode(data)),
    onError: (Object _) {
      if (!done.isCompleted) done.complete();
    },
    onDone: () {
      if (!done.isCompleted) done.complete();
    },
  );
  socket.write(
    'GET / HTTP/1.1\r\n'
    'Host: 127.0.0.1:$port\r\n'
    'Upgrade: websocket\r\n'
    'Connection: Upgrade\r\n'
    'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n'
    'Sec-WebSocket-Key: c2Vjb25kIG5vbmNlIGhlcmU=\r\n'
    'Sec-WebSocket-Version: 13\r\n\r\n',
  );
  await socket.flush();
  await done.future.timeout(
    const Duration(seconds: 5),
    onTimeout: () => socket.destroy(),
  );
  return answer.toString().split('\r\n').first;
}

void main() {
  for (final compressed in [false, true]) {
    test('compression ${compressed ? 'on' : 'off'}: the request is refused and '
        'the server keeps serving', () async {
      final http = await HttpServer.bind('127.0.0.1', 0);
      final server = RpcWebSocketServer(
        connections: rpcWebSocketConnections(
          http,
          compression: compressed
              ? CompressionOptions.compressionDefault
              : CompressionOptions.compressionOff,
        ),
        onEndpointCreated: (e) => e.registerServiceContract(_Echo()),
      );
      await server.start();
      addTearDown(() async {
        await server.stop();
        await http.close(force: true);
      });

      // An error escaping to the zone fails this test as uncaught.
      expect(await _twoKeys(http.port), contains('400'));

      final client = await RpcWebSocketCallerTransport.connect(
        Uri.parse('ws://127.0.0.1:${http.port}'),
      );
      final caller = RpcCallerEndpoint(transport: client);
      addTearDown(() async {
        await caller.close();
        await client.close();
      });
      final answer = await caller.unaryRequest<RpcString, RpcString>(
        serviceName: 'Svc',
        methodName: 'echo',
        request: 'ping'.rpc,
        requestCodec: _codec,
        responseCodec: _codec,
      );
      expect(answer.value, 'ping');
    });
  }
}
