// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// When the PEER dies and a reconnect factory is configured, the wrapper stays
// un-closed on purpose -- so `reconnect()` can re-attach and subscribers to the
// stable incomingMessages survive. It stayed SILENT about it too, and that was
// the bug: `_inner` had closed itself via onDone, and RpcChannelTransport
// answers a closed transport QUIETLY -- sendMetadata is a no-op,
// getMessagesForStream returns Stream.empty().
//
// A call made after the peer died therefore reached a closed inner transport,
// and the pipeline raised RpcStatusException(14) from a detached subscription
// into the ROOT zone:
//
//   before: Unhandled exception: RpcStatusException(14): Stream closed without
//           receiving response   -- the process ended
//           isClosed == false, while health() (delegating to the closed inner
//           transport) said "Transport is closed"
//   after : the call throws StateError naming the state, health() reports
//           DEGRADED "Reconnect is required", and the process lives
//
// 3bfa7715 fixed exactly this fault on the FAILED-RECONNECT path. This is the
// plain peer-death path, which needs no reconnect call at all -- any server
// restart or dropped network reaches it.

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

class _Peer {
  _Peer(this._http, this._transports);
  final HttpServer _http;
  final List<RpcWebSocketResponderTransport> _transports;

  int get port => _http.port;

  static Future<_Peer> start([int port = 0]) async {
    final transports = <RpcWebSocketResponderTransport>[];
    final http = await HttpServer.bind('127.0.0.1', port);
    http.transform(WebSocketTransformer()).listen((ws) {
      final t = RpcWebSocketResponderTransport(IOWebSocketChannel(ws));
      transports.add(t);
      final responder = RpcResponderEndpoint(transport: t);
      responder.registerServiceContract(_Contract());
      responder.start();
    });
    return _Peer(http, transports);
  }

  /// Upgraded websockets are detached from the HttpServer, so closing it -- even
  /// with force: true -- does NOT kill them. The peer only dies when the
  /// server-side transports close.
  Future<void> die() async {
    for (final t in _transports) {
      await t.close();
    }
    await _http.close(force: true);
  }
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
  test('a call after the peer dies fails cleanly, not fatally', () async {
    final peer = await _Peer.start();
    final client = await RpcWebSocketCallerTransport.connect(
      Uri.parse('ws://127.0.0.1:${peer.port}'),
    );
    final caller = RpcCallerEndpoint(transport: client);
    addTearDown(() async {
      await caller.close();
      await client.close();
    });

    expect(await _echo(caller), 'echo-ok');

    await peer.die();
    await Future<void>.delayed(const Duration(seconds: 1));

    expect(
      await _echo(caller),
      contains('disconnected'),
      reason:
          'the call reached a CLOSED inner transport, whose empty per-stream '
          'stream made the pipeline raise RpcStatusException(14) into the root '
          'zone and end the process',
    );
    // Reaching this line is the other half of the assertion: before the fix the
    // isolate was already gone.
    expect(await _echo(caller), contains('disconnected'));
  });

  test('the state after peer death is coherent', () async {
    final peer = await _Peer.start();
    final client = await RpcWebSocketCallerTransport.connect(
      Uri.parse('ws://127.0.0.1:${peer.port}'),
    );
    addTearDown(client.close);

    await peer.die();
    await Future<void>.delayed(const Duration(seconds: 1));

    expect(
      client.isClosed,
      isFalse,
      reason: 'a reconnect factory is configured, so this is recoverable',
    );
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

  test('it recovers when the peer comes back', () async {
    // The whole reason the wrapper stays un-closed: reconnect must work.
    final reserve = await ServerSocket.bind('127.0.0.1', 0);
    final port = reserve.port;
    await reserve.close();

    var peer = await _Peer.start(port);
    final client = await RpcWebSocketCallerTransport.connect(
      Uri.parse('ws://127.0.0.1:$port'),
    );
    final caller = RpcCallerEndpoint(transport: client);
    addTearDown(() async {
      await caller.close();
      await client.close();
    });

    expect(await _echo(caller), 'echo-ok');
    await peer.die();
    await Future<void>.delayed(const Duration(seconds: 1));

    peer = await _Peer.start(port);
    addTearDown(peer.die);
    expect((await client.reconnect()).message, contains('Reconnected'));
    expect(await _echo(caller), 'echo-ok');
    expect((await client.health()).message, contains('ready'));
  });

  test('GUARD: with no reconnect factory the transport closes fully', () async {
    // Nothing to recover to, so peer death is terminal -- and must still be
    // reported as CLOSED rather than as merely disconnected.
    final peer = await _Peer.start();
    final client = RpcWebSocketCallerTransport(
      IOWebSocketChannel.connect(Uri.parse('ws://127.0.0.1:${peer.port}')),
    );
    final caller = RpcCallerEndpoint(transport: client);
    addTearDown(() async {
      await caller.close();
      await client.close();
    });

    expect(await _echo(caller), 'echo-ok');

    await peer.die();
    await Future<void>.delayed(const Duration(seconds: 1));

    expect(client.isClosed, isTrue);
    expect((await client.health()).message, contains('closed'));
    expect(await _echo(caller), contains('closed'));
  });
}
