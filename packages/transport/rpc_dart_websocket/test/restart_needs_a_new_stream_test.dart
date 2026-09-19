// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// RpcWebSocketServer.start() refuses to restart over a single-subscription
// connections stream, and its StateError used to name two remedies:
//
//   "Pass a broadcast stream (Stream.asBroadcastStream()) if the server must
//    restart, or construct a new RpcWebSocketServer."
//
// Driven, one of the two does not work. The obstacle is the STREAM, not the
// server object, so a new RpcWebSocketServer over the same stream throws the
// identical error -- and so would a second rpcWebSocketConnections(http), since
// HttpServer is single-subscription too and the first call already listened to
// it. Over one HttpServer there is no "construct a new server" route at all.
//
//   arm            restart      then
//   single         StateError   -
//   broadcast      ok           served
//   fresh server   StateError   -        <- the remedy that did not work
//
// The remedy that DOES work has a hole the message did not mention: while the
// server is stopped the HttpServer keeps accepting and upgrading, the broadcast
// stream drops the event, and the peer is left holding an open socket.
// Measured -- handshake accepted, nothing closed it three seconds later, a call
// over it HUNG. Filed as B-59; this file pins the behaviour so a fix has a
// baseline.

@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_websocket/io.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Svc extends RpcResponderContract {
  _Svc() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'echo',
      handler: (r, {RpcContext? context}) async => 'ok'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

/// One call over a fresh connection; reports rather than throws.
Future<String> _call(int port) async {
  RpcWebSocketCallerTransport? transport;
  RpcCallerEndpoint? caller;
  try {
    final t = await RpcWebSocketCallerTransport.connect(
      Uri.parse('ws://127.0.0.1:$port'),
      connectTimeout: const Duration(seconds: 5),
    ).timeout(const Duration(seconds: 5));
    transport = t;
    caller = RpcCallerEndpoint(transport: t);
    final r = await caller
        .unaryRequest<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: 'echo',
          request: 'x'.rpc,
          requestCodec: _codec,
          responseCodec: _codec,
        )
        .timeout(const Duration(seconds: 5));
    return r.value == 'ok' ? 'served' : 'WRONG(${r.value})';
  } on TimeoutException {
    return 'HUNG';
  } catch (e) {
    return 'FAILED(${e.runtimeType})';
  } finally {
    await caller?.close().catchError((_) {});
    await transport?.close().catchError((_) {});
  }
}

void main() {
  late HttpServer http;

  setUp(() async => http = await HttpServer.bind('127.0.0.1', 0));
  tearDown(() => http.close(force: true));

  RpcWebSocketServer serverOver(Stream<WebSocketChannel> connections) =>
      RpcWebSocketServer(
        connections: connections,
        onEndpointCreated: (e) => e.registerServiceContract(_Svc()),
      );

  // WITNESS for the message change. The behaviour below was always true; what
  // was wrong is what the server TOLD an operator to do about it.
  test('the restart error names the stream, not the server', () async {
    final server = serverOver(rpcWebSocketConnections(http));
    await server.start();
    await server.stop();

    final error = await server.start().then<Object?>(
      (_) => null,
      onError: (Object e) => e,
    );

    expect(error, isA<StateError>());
    final message = (error! as StateError).message;
    expect(
      message,
      contains('SAME stream does not help'),
      reason:
          'the old message offered "construct a new RpcWebSocketServer" as a '
          'remedy, and that fails identically: "$message"',
    );
    expect(
      message,
      contains('no close'),
      reason: 'the working remedy has a gap and the message must say so',
    );
  });

  // The FACT the message now states. True before the change too: this is the
  // evidence behind it, not a witness for it.
  test('a new server over the same stream fails identically', () async {
    final connections = rpcWebSocketConnections(http);

    final first = serverOver(connections);
    await first.start();
    expect(await _call(http.port), 'served');
    await first.stop();

    final second = serverOver(connections);
    await expectLater(second.start(), throwsA(isA<StateError>()));
    expect(second.isRunning, isFalse);
  });

  // GUARD: the remedy that works must keep working.
  test('a broadcast stream restarts and serves', () async {
    final server = serverOver(
      rpcWebSocketConnections(http).asBroadcastStream(),
    );

    await server.start();
    expect(await _call(http.port), 'served');
    await server.stop();

    await server.start();
    expect(server.isRunning, isTrue);
    expect(await _call(http.port), 'served');

    await server.stop();
  });

  // B-59's baseline. A peer that arrives in the gap completes the handshake and
  // is then held by nobody: nothing answers it and nothing closes it.
  test('a peer arriving while stopped is accepted and abandoned', () async {
    final server = serverOver(
      rpcWebSocketConnections(http).asBroadcastStream(),
    );
    await server.start();
    await server.stop();

    final closedAt = Completer<void>();
    final ws = WebSocketChannel.connect(
      Uri.parse('ws://127.0.0.1:${http.port}'),
    );
    await ws.ready.timeout(const Duration(seconds: 5));
    // Either ending counts as "the peer was told something".
    unawaited(
      ws.stream
          .drain<void>()
          .whenComplete(() {
            if (!closedAt.isCompleted) closedAt.complete();
          })
          .catchError((Object _) {}),
    );

    // Snapshot BEFORE any teardown: a first version of the probe read this
    // after closing its own socket and reported "closed".
    await Future<void>.delayed(const Duration(seconds: 2));
    expect(
      closedAt.isCompleted,
      isFalse,
      reason:
          'if a stopped server now closes what it cannot serve, B-59 is fixed '
          'and this expectation is the thing to invert',
    );

    await ws.sink.close().catchError((Object _) {});
    await server.start();
    expect(await _call(http.port), 'served');
    await server.stop();
  });
}
