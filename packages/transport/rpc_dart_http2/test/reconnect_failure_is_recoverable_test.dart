// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A FAILED reconnect() used to set `_isClosed = true` -- the same flag close()
// sets -- and three places read that flag with three different meanings:
//
//   health()          "disconnected, reconnect required"  -> DEGRADED
//   the send paths    "closed"                            -> throw
//   reconnect()'s post-factory re-check (48847ffc)
//                     "the caller closed us"              -> discard and refuse
//
// So the transport told you to reconnect and then refused every attempt. One
// failed reconnect was terminal, and retry-with-backoff -- the only way anyone
// drives a reconnect API -- could never recover.
//
// Measured with viaSocket, whose factory is documented to always throw, so the
// connection stays healthy and only the reconnect attempt fails:
//
//   before: isClosed false -> TRUE, calls "Bad state: Transport is closed",
//           a second reconnect returns "Transport closed during reconnect"
//   after : isClosed stays false, health DEGRADED "connection is down",
//           calls name the state, and a second reconnect still tries
//
// The un-close removed in 48847ffc stays removed: close() during an in-flight
// reconnect must still win. That is now a separate flag rather than the same
// one, which is what let both be true at once.

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';
import 'package:test/test.dart';

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

Future<RpcHttp2Server> _startServer() async {
  final server = RpcHttp2Server(
    host: '127.0.0.1',
    port: 0,
    onEndpointCreated: (e) => e.registerServiceContract(_Contract()),
  );
  await server.start();
  addTearDown(server.stop);
  return server;
}

/// A transport whose reconnect factory ALWAYS throws, by construction, over a
/// connection that stays healthy. Isolates "the reconnect attempt failed" from
/// "the connection died".
Future<RpcHttp2CallerTransport> _viaSocketClient(RpcHttp2Server server) async {
  final socket = await Socket.connect('127.0.0.1', server.port);
  final client = RpcHttp2CallerTransport.viaSocket(
    socket,
    host: '127.0.0.1',
    port: server.port,
    scheme: 'http',
  );
  addTearDown(client.close);
  return client;
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
        .timeout(const Duration(seconds: 10));
    return r.value;
  } catch (e) {
    return 'FAILED $e';
  }
}

void main() {
  test('a failed reconnect leaves the transport open, not closed', () async {
    final server = await _startServer();
    final client = await _viaSocketClient(server);
    final caller = RpcCallerEndpoint(transport: client);
    addTearDown(caller.close);

    expect(await _echo(caller), 'echo-ok');
    expect(client.isClosed, isFalse);

    final failed = await client.reconnect();
    expect(failed.message, contains('Failed to reconnect'));

    expect(
      client.isClosed,
      isFalse,
      reason:
          'the caller never closed this transport; marking it closed made the '
          'first reconnect failure terminal',
    );
  });

  test('a failed reconnect still reports as recoverable', () async {
    final server = await _startServer();
    final client = await _viaSocketClient(server);
    addTearDown(client.close);

    await client.reconnect();

    final health = await client.health();
    expect(health.message, contains('Reconnect is required'));
    expect(
      health.message,
      isNot(contains('transport closed')),
      reason:
          'health told the caller to reconnect while every other path '
          'claimed the transport was closed',
    );
  });

  test('a second reconnect attempt is still made', () async {
    // THE witness. Retry-with-backoff calls reconnect repeatedly; the second
    // attempt used to be refused outright by the post-factory re-check reading
    // the failure flag as "the caller closed us".
    final server = await _startServer();
    final client = await _viaSocketClient(server);
    addTearDown(client.close);

    await client.reconnect();
    final second = await client.reconnect();

    expect(
      second.message,
      contains('Failed to reconnect'),
      reason:
          'the second attempt must reach the factory again; it used to return '
          '"Transport closed during reconnect" and give up for good',
    );
  });

  test('a disconnected transport says so, and says what to do', () async {
    final server = await _startServer();
    final client = await _viaSocketClient(server);
    final caller = RpcCallerEndpoint(transport: client);
    addTearDown(caller.close);

    await client.reconnect();

    final outcome = await _echo(caller);
    expect(outcome, contains('disconnected'));
    expect(outcome, contains('reconnect()'));
  });

  group('close() is still terminal', () {
    // GUARDS: splitting the flag must not weaken close(), and must not undo
    // 48847ffc -- a close during an in-flight reconnect still wins.
    test('close() closes, and reconnect refuses afterwards', () async {
      final server = await _startServer();
      final client = await _viaSocketClient(server);

      await client.close();

      expect(client.isClosed, isTrue);
      expect((await client.health()).message, contains('closed'));
      expect(
        (await client.reconnect()).message,
        contains('closed'),
        reason: 'a closed transport must never reconnect itself',
      );
    });

    test('a live transport reconnects normally, repeatedly', () async {
      // GUARD: the ordinary success path, which shares every line changed here.
      final server = await _startServer();
      final client = await RpcHttp2CallerTransport.connect(
        host: '127.0.0.1',
        port: server.port,
      );
      final caller = RpcCallerEndpoint(transport: client);
      addTearDown(() async {
        await caller.close();
        await client.close();
      });

      expect(await _echo(caller), 'echo-ok');
      for (var i = 0; i < 3; i++) {
        final status = await client.reconnect();
        expect(status.message, contains('re-established'), reason: 'round $i');
        expect(client.isClosed, isFalse);
        expect(await _echo(caller), 'echo-ok', reason: 'round $i');
      }
      expect((await client.health()).message, contains('ready'));
    });
  });
}
