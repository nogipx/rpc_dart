// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A peer client could RECEIVE a call and could never ANSWER one.
//
// `RpcWebSocketCallerTransport` guards its sends with `_idsOnThisConnection`,
// a set fed only by `createStream()`. That is right for the streams it opens --
// a teardown landing after a reconnect must not act on whichever call now holds
// the number -- but a response travels on the id the REMOTE chose, which is by
// construction never in that set. So every frame of every answer was dropped,
// silently, with no error anywhere:
//
//   arm                          handler ran   caller got
//   reverse unary, before        yes           TimeoutException after 8s
//   reverse unary, after         yes           the response, in 26ms
//
// Found by a consumer that puts the permission decision for a headless agent on
// the reverse direction of the same socket the conversation runs on.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_websocket/io.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

/// Registered on the CLIENT, called by the server.
final class _Answering extends RpcPeerContract {
  _Answering(RpcPeerEndpoint endpoint) : super('Reverse', endpoint);

  var calls = 0;

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'Ask',
      handler: (request, {RpcContext? context}) async {
        calls++;
        return 'answered ${request.value}'.rpc;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

/// The server's caller half for the same service.
final class _Asking extends RpcPeerContract {
  _Asking(RpcPeerEndpoint endpoint) : super('Reverse', endpoint);

  @override
  void setup() {}

  Future<String> ask(String what) async {
    final reply = await callUnary<RpcString, RpcString>(
      methodName: 'Ask',
      request: what.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    );
    return reply.value;
  }
}

void main() {
  late HttpServer http;
  late RpcWebSocketServer server;
  late RpcWebSocketCallerTransport transport;
  late RpcPeerEndpoint clientPeer;

  tearDown(() async {
    await clientPeer.close().catchError((Object _) {});
    await transport.close().catchError((Object _) {});
    await server.dispose().catchError((Object _) {});
    await http.close(force: true);
  });

  /// A connected peer pair: the server can call the client.
  Future<(_Asking, _Answering)> connectPair() async {
    http = await HttpServer.bind('127.0.0.1', 0);
    final built = Completer<RpcPeerEndpoint>();
    server = RpcWebSocketServer(
      connections: rpcWebSocketConnections(http),
      onPeerEndpointCreated: (endpoint) {
        if (!built.isCompleted) built.complete(endpoint);
      },
    );
    await server.start();

    transport = await RpcWebSocketCallerTransport.connect(
      Uri.parse('ws://127.0.0.1:${http.port}'),
    );
    clientPeer = RpcPeerEndpoint(transport: transport);
    final answering = _Answering(clientPeer);
    clientPeer.registerServiceContract(answering);
    clientPeer.start();

    return (_Asking(await built.future), answering);
  }

  test(
    'a peer client answers a call the server started',
    () async {
      final (asking, answering) = await connectPair();

      expect(
        await asking.ask('hello').timeout(const Duration(seconds: 10)),
        'answered hello',
        reason:
            'the response went out on an id the client did not mint, so the '
            'send guard dropped every frame of it',
      );
      expect(answering.calls, 1);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'it goes on answering, so the id set does not leak or go stale',
    () async {
      // The second call is the one that catches a fix that lets the first
      // through and then forgets -- or never retires the id and grows forever.
      final (asking, answering) = await connectPair();

      for (var i = 0; i < 5; i++) {
        expect(
          await asking.ask('n$i').timeout(const Duration(seconds: 10)),
          'answered n$i',
        );
      }
      expect(answering.calls, 5);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'calls in BOTH directions share the connection',
    () async {
      // The client still has to be able to call the server, which is what the
      // guard was protecting in the first place.
      final (asking, _) = await connectPair();
      final serverPeer = await () async {
        final endpoint = asking.endpoint;
        endpoint.registerServiceContract(_Answering(endpoint));
        return endpoint;
      }();
      expect(serverPeer.isActive, isTrue);

      final fromClient = _Asking(clientPeer);
      final results = await Future.wait([
        asking.ask('down'),
        fromClient.ask('up'),
      ]).timeout(const Duration(seconds: 15));

      expect(results, ['answered down', 'answered up']);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
