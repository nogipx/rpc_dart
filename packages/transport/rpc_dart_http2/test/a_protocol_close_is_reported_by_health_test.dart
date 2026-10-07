// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A responder that ends its connection for a protocol violation no longer
// reports itself healthy.

@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:http2/http2.dart' as http2;
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';
import 'package:test/test.dart';

void main() {
  test('health after a protocol close is not healthy', () async {
    final endpoints = <RpcResponderEndpoint>[];
    final server = RpcHttp2Server(
      host: '127.0.0.1',
      port: 0,
      securityPolicy: const RpcSecurityPolicy(closeOnProtocolError: true),
      onEndpointCreated: endpoints.add,
    );
    await server.start();
    addTearDown(server.stop);

    final socket = await Socket.connect('127.0.0.1', server.port);
    final conn = http2.ClientTransportConnection.viaSocket(socket);
    addTearDown(() => conn.terminate().catchError((Object _) {}));
    // No leading slash: a path the responder refuses as a violation.
    final stream = conn.makeRequest([
      http2.Header.ascii(':method', 'POST'),
      http2.Header.ascii(':path', 'Svc/ping'),
      http2.Header.ascii(':scheme', 'http'),
      http2.Header.ascii(':authority', '127.0.0.1:${server.port}'),
      http2.Header.ascii('content-type', 'application/grpc+proto'),
      http2.Header.ascii('te', 'trailers'),
    ], endStream: true);
    unawaited(stream.incomingMessages.drain<void>().catchError((Object _) {}));

    await Future<void>.delayed(const Duration(seconds: 1));
    expect(conn.isOpen, isFalse, reason: 'the premise: the server closed');

    expect(endpoints, hasLength(1));
    final health = await endpoints.single.transport.health();
    expect(health.level, isNot(RpcHealthLevel.healthy), reason: '$health');
  });
}
