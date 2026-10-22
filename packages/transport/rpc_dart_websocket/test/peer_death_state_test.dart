// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// When the PEER dies, RpcWebSocketCallerTransport closes itself: reconnecting
// is RpcClientConnection's job, and it learns of the drop from this transport's
// message stream ending.
//
// A call made after that must fail as a status the caller can catch. The
// failure this pins is the quiet one: a closed RpcChannelTransport answers
// sendMetadata as a no-op and getMessagesForStream with Stream.empty(), and
// the caller pipeline then raises RpcStatusException(14) from a detached
// subscription into the ROOT zone, which ends the process. The call must
// instead throw UNAVAILABLE -- the peer is gone, and a retry through a new
// connection is the remedy -- and the state must read closed everywhere.

@TestOn('vm')
library;

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

  static Future<_Peer> start() async {
    final transports = <RpcWebSocketResponderTransport>[];
    final http = await HttpServer.bind('127.0.0.1', 0);
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

/// The reply, 'HUNG', or the status code the call failed with.
Future<Object> _echo(RpcCallerEndpoint caller) async {
  try {
    final r = await caller
        .unary<RpcString, RpcString>(
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
  } on RpcStatusException catch (e) {
    return e.statusCode;
  } catch (e) {
    return 'caught: $e';
  }
}

Future<void> _untilClosed(IRpcTransport t) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!t.isClosed && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  test(
    'a call after the peer dies fails as UNAVAILABLE, not fatally',
    () async {
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
      await _untilClosed(client);

      expect(
        await _echo(caller),
        RpcStatus.unavailable,
        reason:
            'a call on a closed channel transport must be refused as a status; '
            'an empty per-stream stream makes the pipeline raise into the root '
            'zone and end the process',
      );
      // Reaching this line is the other half of the assertion: a raise into the
      // root zone would have ended the isolate already.
      expect(await _echo(caller), RpcStatus.unavailable);
    },
  );

  test('the state after peer death reads closed everywhere', () async {
    final peer = await _Peer.start();
    final client = await RpcWebSocketCallerTransport.connect(
      Uri.parse('ws://127.0.0.1:${peer.port}'),
    );
    addTearDown(client.close);

    final ended = Completer<void>();
    client.incomingMessages.listen(
      (_) {},
      onError: (Object _) {},
      onDone: ended.complete,
    );

    await peer.die();
    await ended.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () => fail(
        'incomingMessages did not end, so RpcClientConnection would never '
        'learn of the drop',
      ),
    );

    expect(client.isClosed, isTrue);
    expect((await client.health()).message, contains('closed'));
  });
}
