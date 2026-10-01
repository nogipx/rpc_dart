// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// RpcWebSocketServer had no ceiling on concurrent connections: each one costs
// an endpoint, a transport and their buffers, and nothing refused the next.

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
      handler: (request, {RpcContext? context}) async => request,
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

/// One call on a fresh client; returns the answer or the error's first line.
Future<String> _call(Uri url) async {
  final client = await RpcWebSocketCallerTransport.connect(url);
  final caller = RpcCallerEndpoint(transport: client);
  try {
    final answer = await caller
        .unaryRequest<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: 'echo',
          request: 'x'.rpc,
          requestCodec: _codec,
          responseCodec: _codec,
        )
        .timeout(const Duration(seconds: 5));
    return answer.value;
  } catch (e) {
    return e.toString().split('\n').first;
  } finally {
    await caller.close();
    await client.close();
  }
}

void main() {
  test('connections past maxConnections are refused, and the slot '
      'comes back', () async {
    final http = await HttpServer.bind('127.0.0.1', 0);
    var opened = 0;
    final server = RpcWebSocketServer(
      connections: rpcWebSocketConnections(http),
      maxConnections: 2,
      onEndpointCreated: (e) {
        opened++;
        e.registerServiceContract(_Echo());
      },
    );
    await server.start();
    final url = Uri.parse('ws://127.0.0.1:${http.port}');
    addTearDown(() async {
      await server.stop();
      await http.close(force: true);
    });

    // Two held open.
    final held = [
      await RpcWebSocketCallerTransport.connect(url),
      await RpcWebSocketCallerTransport.connect(url),
    ];
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (opened < 2 && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(opened, 2);

    expect(
      await _call(url),
      isNot('x'),
      reason: 'a third connection was served past maxConnections: 2',
    );
    expect(opened, 2, reason: 'an endpoint was built for the refused one');

    // Releasing one gives its slot back.
    await held.removeAt(0).close();
    final back = DateTime.now().add(const Duration(seconds: 5));
    var answer = '';
    while (DateTime.now().isBefore(back)) {
      answer = await _call(url);
      if (answer == 'x') break;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(answer, 'x', reason: 'a closed connection did not free its slot');

    for (final t in held) {
      await t.close();
    }
  });

  test('refusals at the limit warn once, not once per attempt', () async {
    final logs = LogController(minLevel: RpcLogLevel.warning);
    final warnings = <LogEvent>[];
    final sub = logs.stream.listen((r) {
      if (r is LogEvent && r.message.contains('connection limit')) {
        warnings.add(r);
      }
    });
    final http = await HttpServer.bind('127.0.0.1', 0);
    final server = RpcWebSocketServer(
      connections: rpcWebSocketConnections(http),
      logger: LogScope(logs, 'Test'),
      maxConnections: 1,
      onEndpointCreated: (e) => e.registerServiceContract(_Echo()),
    );
    await server.start();
    final url = Uri.parse('ws://127.0.0.1:${http.port}');
    addTearDown(() async {
      await server.stop();
      await http.close(force: true);
      await sub.cancel();
    });
    final held = await RpcWebSocketCallerTransport.connect(url);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    for (var i = 0; i < 5; i++) {
      await _call(url);
    }
    expect(warnings, hasLength(1), reason: '${warnings.length} warnings');
    await held.close();
  });

  test('CONTROL: no cap by default', () async {
    final http = await HttpServer.bind('127.0.0.1', 0);
    final server = RpcWebSocketServer(
      connections: rpcWebSocketConnections(http),
      onEndpointCreated: (e) => e.registerServiceContract(_Echo()),
    );
    await server.start();
    final url = Uri.parse('ws://127.0.0.1:${http.port}');
    addTearDown(() async {
      await server.stop();
      await http.close(force: true);
    });
    final held = [
      for (var i = 0; i < 4; i++)
        await RpcWebSocketCallerTransport.connect(url),
    ];
    expect(await _call(url), 'x');
    for (final t in held) {
      await t.close();
    }
  });
}
