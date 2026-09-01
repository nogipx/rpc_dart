// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// RpcWebSocketServer leaked an endpoint per connection.
//
//  1. _endpoints was a List<RpcResponderEndpoint>, which a RpcPeerEndpoint
//     structurally cannot join -- they are sibling subclasses of
//     RpcEndpointBase. Peer-mode endpoints were therefore never tracked, and
//     stop() (which closes what it finds in that list) never closed them.
//  2. Neither branch closed the endpoint when its connection dropped: the
//     responder branch only removed it from the list, the peer branch did
//     nothing.
//
// An endpoint dropped without close() never disposes its registered
// contracts, so whatever a contract holds -- database handles, files,
// subscriptions -- stays held for the life of the process. One leak per
// client disconnect, which on a server is unbounded.

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Records whether the server disposed the contract it registered.
class _DisposeSpy extends RpcResponderContract {
  _DisposeSpy(this.onDisposed) : super('Spy');

  final void Function() onDisposed;

  @override
  void setup() {}

  @override
  void dispose() {
    onDisposed();
    super.dispose();
  }
}

Future<({RpcWebSocketServer server, HttpServer http, Uri url})> _start({
  required void Function(RpcEndpointBase endpoint) register,
  required bool peerMode,
}) async {
  final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final channels = StreamController<WebSocketChannel>.broadcast();

  unawaited(() async {
    await for (final request in http) {
      final socket = await WebSocketTransformer.upgrade(request);
      channels.add(IOWebSocketChannel(socket));
    }
  }());

  final server = RpcWebSocketServer(
    connections: channels.stream,
    onEndpointCreated: peerMode ? null : register,
    onPeerEndpointCreated: peerMode ? register : null,
  );
  await server.start();

  return (
    server: server,
    http: http,
    url: Uri.parse('ws://${http.address.address}:${http.port}'),
  );
}

void main() {
  for (final peerMode in [false, true]) {
    final label = peerMode ? 'peer' : 'responder';

    test('$label endpoint is disposed when its connection drops', () async {
      var disposed = 0;
      final s = await _start(
        peerMode: peerMode,
        register: (endpoint) {
          if (endpoint is RpcResponderEndpoint) {
            endpoint.registerServiceContract(_DisposeSpy(() => disposed++));
          } else if (endpoint is RpcPeerEndpoint) {
            endpoint.registerServiceContract(_DisposeSpy(() => disposed++));
          }
        },
      );

      final client = WebSocketChannel.connect(s.url);
      await client.ready;
      await Future<void>.delayed(const Duration(milliseconds: 200));

      await client.sink.close();
      await Future<void>.delayed(const Duration(milliseconds: 500));

      expect(
        disposed,
        1,
        reason:
            'the endpoint was dropped without close(), so its contract '
            'never released what it held',
      );

      await s.server.stop();
      await s.http.close(force: true);
    });

    test('$label endpoint is disposed when the server stops', () async {
      var disposed = 0;
      final s = await _start(
        peerMode: peerMode,
        register: (endpoint) {
          if (endpoint is RpcResponderEndpoint) {
            endpoint.registerServiceContract(_DisposeSpy(() => disposed++));
          } else if (endpoint is RpcPeerEndpoint) {
            endpoint.registerServiceContract(_DisposeSpy(() => disposed++));
          }
        },
      );

      final client = WebSocketChannel.connect(s.url);
      await client.ready;
      await Future<void>.delayed(const Duration(milliseconds: 200));

      // Stop with the connection still open: stop() must close every endpoint
      // it created, peer-mode ones included.
      await s.server.stop();
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(
        disposed,
        1,
        reason: 'stop() never saw this endpoint, so it was never closed',
      );

      await client.sink.close();
      await s.http.close(force: true);
    });
  }
}
