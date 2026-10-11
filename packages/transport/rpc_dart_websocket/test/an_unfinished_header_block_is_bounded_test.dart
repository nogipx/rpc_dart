// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// dart:io holds an unfinished request header block below every rpc_dart
// limit, for as long as the client keeps the connection open. An HttpServer
// bound with bindRpcWebSocketHttpServer closes a connection whose block is
// too long or too slow, as RpcHttpServer does for its own socket.

@TestOn('vm')
library;

import 'dart:async';
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

Future<HttpServer> _serve({
  Duration? headerTimeout = const Duration(seconds: 60),
  int? maxConnections,
  int? maxHeaderBytes,
}) async {
  final io = await bindRpcWebSocketHttpServer(
    '127.0.0.1',
    0,
    headerTimeout: headerTimeout,
    maxConnections: maxConnections,
    maxHeaderBytes: maxHeaderBytes,
  );
  final server = RpcWebSocketServer(
    connections: rpcWebSocketConnections(io),
    onEndpointCreated: (e) => e.registerServiceContract(_Echo()),
  );
  await server.start();
  addTearDown(() async {
    await server.stop();
    await io.close(force: true);
  });
  return io;
}

/// Opens a raw connection, sends [bytes] of an upgrade request whose header
/// block never ends, and returns when the server closes it, or 'open' after
/// [wait].
Future<String> _hold(int port, int bytes, Duration wait) async {
  final s = await Socket.connect('127.0.0.1', port);
  final closed = Completer<String>();
  s.listen(
    (_) {},
    onDone: () => closed.isCompleted ? null : closed.complete('closed'),
    onError: (Object _) =>
        closed.isCompleted ? null : closed.complete('closed'),
  );
  s.write('GET / HTTP/1.1\r\nhost: x\r\nupgrade: websocket\r\n');
  final line = 'x-pad: ${'a' * 100}\r\n';
  for (var sent = 0; sent < bytes; sent += line.length) {
    s.write(line);
  }
  unawaited(s.flush().catchError((Object _) {}));
  final outcome = await closed.future.timeout(wait, onTimeout: () => 'open');
  s.destroy();
  return outcome;
}

Future<String> _call(int port) async {
  final transport = await RpcWebSocketCallerTransport.connect(
    Uri.parse('ws://127.0.0.1:$port/'),
  );
  final caller = RpcCallerEndpoint(transport: transport);
  try {
    return (await caller.unaryRequest<RpcString, RpcString>(
      serviceName: 'Svc',
      methodName: 'echo',
      request: 'ok'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    )).value;
  } finally {
    await caller.close();
  }
}

void main() {
  test('WITNESS: a header block over the byte bound is cut', () async {
    final io = await _serve(maxHeaderBytes: 16 * 1024);
    expect(
      await _hold(io.port, 64 * 1024, const Duration(seconds: 5)),
      'closed',
    );
  });

  test(
    'WITNESS: a header block that never ends is cut at the timeout',
    () async {
      final io = await _serve(headerTimeout: const Duration(milliseconds: 300));
      expect(await _hold(io.port, 100, const Duration(seconds: 5)), 'closed');
    },
  );

  test('GUARD: without the timeout the same block is held', () async {
    final io = await _serve(headerTimeout: null);
    expect(await _hold(io.port, 100, const Duration(seconds: 1)), 'open');
  });

  test('GUARD: an honest client is served through the bound', () async {
    final io = await _serve(headerTimeout: const Duration(seconds: 2));
    expect(await _call(io.port), 'ok');
    // A call well after the deadline: the bound ends with the header block.
    final transport = await RpcWebSocketCallerTransport.connect(
      Uri.parse('ws://127.0.0.1:${io.port}/'),
    );
    final caller = RpcCallerEndpoint(transport: transport);
    addTearDown(caller.close);
    await Future<void>.delayed(const Duration(milliseconds: 2500));
    final answer = await caller.unaryRequest<RpcString, RpcString>(
      serviceName: 'Svc',
      methodName: 'echo',
      request: 'later'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    );
    expect(answer.value, 'later');
  });

  test('WITNESS: a connection past maxConnections is refused', () async {
    final io = await _serve(maxConnections: 1);
    final first = Socket.connect('127.0.0.1', io.port);
    final held = await first;
    addTearDown(held.destroy);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(await _hold(io.port, 10, const Duration(seconds: 3)), 'closed');
  });

  test('GUARD: closing the server releases the port', () async {
    final io = await bindRpcWebSocketHttpServer('127.0.0.1', 0);
    final port = io.port;
    await io.close(force: true);
    final again = await ServerSocket.bind('127.0.0.1', port);
    await again.close();
  });
}
