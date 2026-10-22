// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// bindRpcWebSocketHttpServer's maxConnections counts open connections. A
// WebSocket connection returns its slot when it ends, whoever ends it, so the
// cap never fills with connections that are gone.

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

Future<int> _serve({required int maxConnections}) async {
  final io = await bindRpcWebSocketHttpServer(
    '127.0.0.1',
    0,
    maxConnections: maxConnections,
  );
  final server = RpcWebSocketServer(
    connections: rpcWebSocketConnections(
      io,
      pingInterval: const Duration(milliseconds: 200),
    ),
    mode: RpcResponderMode((e) => e.registerServiceContract(_Echo())),
  );
  await server.start();
  addTearDown(() async {
    await server.stop();
    await io.close(force: true);
  });
  return io.port;
}

Future<RpcCallerEndpoint> _open(int port) async => RpcCallerEndpoint(
  transport: await RpcWebSocketCallerTransport.connect(
    Uri.parse('ws://127.0.0.1:$port/'),
  ),
);

Future<String> _echo(RpcCallerEndpoint caller) async =>
    (await caller
            .unary<RpcString, RpcString>(
              serviceName: 'Svc',
              methodName: 'echo',
              request: 'ok'.rpc,
              requestCodec: _codec,
              responseCodec: _codec,
            )
            .timeout(const Duration(seconds: 5)))
        .value;

/// Whether a fresh client is served, polled until [within].
Future<bool> _servedWithin(int port, Duration within) async {
  final until = DateTime.now().add(within);
  while (DateTime.now().isBefore(until)) {
    try {
      final caller = await _open(port);
      try {
        if (await _echo(caller) == 'ok') return true;
      } finally {
        await caller.close();
      }
    } catch (_) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }
  return false;
}

/// Completes the upgrade on a raw socket, then never answers a ping.
Future<void> _upgradeAndGoSilent(int port) async {
  final s = await Socket.connect('127.0.0.1', port);
  addTearDown(s.destroy);
  final answered = Completer<void>();
  s.listen(
    (_) => answered.isCompleted ? null : answered.complete(),
    onDone: () => answered.isCompleted ? null : answered.complete(),
    onError: (Object _) => answered.isCompleted ? null : answered.complete(),
  );
  final key = base64.encode(List<int>.generate(16, (i) => i));
  s.write(
    'GET / HTTP/1.1\r\nhost: 127.0.0.1\r\nupgrade: websocket\r\n'
    'connection: Upgrade\r\nsec-websocket-version: 13\r\n'
    'sec-websocket-key: $key\r\n\r\n',
  );
  await answered.future.timeout(const Duration(seconds: 3));
}

void main() {
  test('WITNESS: a session the client closes returns its slot', () async {
    final port = await _serve(maxConnections: 1);
    for (var i = 0; i < 3; i++) {
      final caller = await _open(port);
      expect(await _echo(caller), 'ok');
      await caller.close();
    }
    expect(await _servedWithin(port, const Duration(seconds: 3)), isTrue);
  });

  test('WITNESS: a session the keepalive ends returns its slot', () async {
    final port = await _serve(maxConnections: 1);
    for (var i = 0; i < 3; i++) {
      await _upgradeAndGoSilent(port);
      expect(await _servedWithin(port, const Duration(seconds: 3)), isTrue);
    }
  });

  test('GUARD: an open session keeps its slot', () async {
    final port = await _serve(maxConnections: 1);
    final held = await _open(port);
    addTearDown(held.close);
    expect(await _echo(held), 'ok');
    expect(await _servedWithin(port, const Duration(seconds: 1)), isFalse);
    expect(await _echo(held), 'ok');
  });
}
