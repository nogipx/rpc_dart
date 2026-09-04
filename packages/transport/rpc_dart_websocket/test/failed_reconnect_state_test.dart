// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// reconnect() closes `_inner` BEFORE calling the factory, so a FAILED attempt
// left this wrapper reporting `isClosed == false` over an inner transport that
// was closed. Every call then delegated into it, and RpcChannelTransport
// answers a closed transport by returning quietly: sendMetadata is a no-op and
// getMessagesForStream hands back Stream.empty(). The caller pipeline saw a
// stream end with no response and raised RpcStatusException(14) from a detached
// subscription -- into the ROOT zone, where it killed the isolate.
//
// Measured: peer dies, reconnect() fails, one call ->
//
//   before: "Unhandled exception: RpcStatusException(14): Stream closed without
//            receiving response" and the process ended. No try/catch around the
//            call could stop it.
//   after : the call throws a StateError naming the state, and the process
//            lives
//
// Without the failed reconnect in between the same sequence always survived,
// which is what pinned the cause to the wrapper's state rather than to the
// outage.
//
// The wrapper also contradicted itself: isClosed said false while health(),
// delegating to the closed inner transport, said "Transport is closed".

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/io.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Contract extends RpcResponderContract {
  _Contract() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'echo',
      handler: (request, {RpcContext? context}) async => 'echo-ok'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

Future<HttpServer> _startServer(int port) async {
  final http = await HttpServer.bind('127.0.0.1', port);
  http.transform(WebSocketTransformer()).listen((ws) {
    final transport = RpcWebSocketResponderTransport(IOWebSocketChannel(ws));
    final responder = RpcResponderEndpoint(transport: transport);
    responder.registerServiceContract(_Contract());
    responder.start();
  });
  return http;
}

/// Reserves a port so the server can be stopped and restarted on the same one,
/// which is what makes the client's reconnect factory point somewhere real.
Future<int> _reservePort() async {
  final socket = await ServerSocket.bind('127.0.0.1', 0);
  final port = socket.port;
  await socket.close();
  return port;
}

Future<String> _echo(RpcCallerEndpoint caller) async {
  try {
    final r = await caller
        .unaryRequest<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: 'echo',
          request: 'x'.rpc,
          requestCodec: _codec,
          responseCodec: _codec,
        )
        .timeout(const Duration(seconds: 5));
    return r.value;
  } on TimeoutException {
    return 'HUNG';
  } catch (e) {
    return 'caught: $e';
  }
}

void main() {
  test('a call after a failed reconnect fails cleanly instead of '
      'killing the isolate', () async {
    final port = await _reservePort();
    final server = await _startServer(port);
    final client = await RpcWebSocketCallerTransport.connect(
      Uri.parse('ws://127.0.0.1:$port'),
    );
    final caller = RpcCallerEndpoint(transport: client);
    addTearDown(() async {
      await caller.close();
      await client.close();
    });

    expect(await _echo(caller), 'echo-ok');

    await server.close(force: true);
    await Future<void>.delayed(const Duration(milliseconds: 400));

    final failed = await client.reconnect();
    expect(failed.message, contains('Reconnect failed'));

    final outcome = await _echo(caller);
    expect(
      outcome,
      contains('disconnected'),
      reason:
          'the call used to reach a CLOSED inner transport, whose empty '
          'per-stream stream made the pipeline raise RpcStatusException(14) '
          'into the root zone and end the process',
    );

    // Reaching here at all is the other half of the assertion: before the fix
    // the isolate was gone by now.
    expect(await _echo(caller), contains('disconnected'));
  });

  test('a failed reconnect leaves consistent state', () async {
    final port = await _reservePort();
    final server = await _startServer(port);
    final client = await RpcWebSocketCallerTransport.connect(
      Uri.parse('ws://127.0.0.1:$port'),
    );
    addTearDown(client.close);

    await server.close(force: true);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    await client.reconnect();

    expect(client.isClosed, isFalse, reason: 'the caller never closed it');
    final health = await client.health();
    expect(health.message, contains('Reconnect is required'));
    expect(
      health.message,
      isNot(contains('Transport is closed')),
      reason:
          'health delegated to the closed inner transport and contradicted '
          'isClosed',
    );
  });

  test('the transport recovers once the peer comes back', () async {
    // THE point of the whole state split: retry-with-backoff must work.
    final port = await _reservePort();
    var server = await _startServer(port);
    final client = await RpcWebSocketCallerTransport.connect(
      Uri.parse('ws://127.0.0.1:$port'),
    );
    final caller = RpcCallerEndpoint(transport: client);
    addTearDown(() async {
      await caller.close();
      await client.close();
    });

    expect(await _echo(caller), 'echo-ok');

    await server.close(force: true);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect((await client.reconnect()).message, contains('Reconnect failed'));

    server = await _startServer(port);
    addTearDown(() => server.close(force: true));
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect((await client.reconnect()).message, contains('Reconnected'));
    expect(await _echo(caller), 'echo-ok');
    expect((await client.health()).message, isNot(contains('down')));
  });

  test('GUARD: an ordinary reconnect on a healthy peer still works', () async {
    final port = await _reservePort();
    final server = await _startServer(port);
    addTearDown(() => server.close(force: true));
    final client = await RpcWebSocketCallerTransport.connect(
      Uri.parse('ws://127.0.0.1:$port'),
    );
    final caller = RpcCallerEndpoint(transport: client);
    addTearDown(() async {
      await caller.close();
      await client.close();
    });

    for (var i = 0; i < 3; i++) {
      expect((await client.reconnect()).message, contains('Reconnected'));
      expect(await _echo(caller), 'echo-ok', reason: 'round $i');
      expect(client.isClosed, isFalse);
    }
  });

  test('GUARD: close() is still terminal', () async {
    final port = await _reservePort();
    final server = await _startServer(port);
    addTearDown(() => server.close(force: true));
    final client = await RpcWebSocketCallerTransport.connect(
      Uri.parse('ws://127.0.0.1:$port'),
    );

    await client.close();

    expect(client.isClosed, isTrue);
    expect((await client.health()).message, contains('closed'));
    expect(() => client.createStream(), throwsStateError);
  });
}
