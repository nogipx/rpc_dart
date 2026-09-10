// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Nagle's algorithm holds a small outbound segment while earlier data is still
// unacknowledged. That is the right trade for a bulk stream and the wrong one
// for an RPC, whose write pattern is precisely what it penalises: a HEADERS
// frame, then a small DATA frame, then a wait for the reply. Every gRPC stack
// turns it off on every connection.
//
// Read back with getRawOption, dart:io left it ON everywhere:
//
//     bare Socket.connect (dart:io default) : TCP_NODELAY false
//     socket accepted by RpcHttp2Server     : TCP_NODELAY false
//
// and exactly one path in this package set it -- the CONNECT-proxy path, on the
// raw socket. Two paths through the same class produced differently configured
// sockets, with the common one as the odd one out.
//
// THE LATENCY BENEFIT IS NOT ASSERTED HERE, because it cannot be measured on
// this machine: loopback acks immediately, so Nagle never engages. The classic
// two-writes-then-wait shape measured 50us with it on and 49us off. What is
// asserted is the option's STATE, which is the thing that was wrong.

@TestOn('vm')
library;

import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
// `disableNagle` comes through the barrel: the package exports its whole
// src/transports/http2 directory.
import 'package:rpc_dart_http2/rpc_dart_http2.dart';
import 'package:rpc_dart_http2/src/transports/http2/rpc_http2_common.dart';
import 'package:test/test.dart';

/// IPPROTO_TCP / TCP_NODELAY, the same on macOS and Linux.
const _ipprotoTcp = 6;
const _tcpNodelay = 1;

final _codec = RpcCodec(RpcString.fromJson);

final class _Svc extends RpcResponderContract {
  _Svc() : super('Svc');

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

bool readNoDelay(Socket socket) {
  final raw = socket.getRawOption(
    RawSocketOption(_ipprotoTcp, _tcpNodelay, Uint8List(4)),
  );
  return raw.buffer.asByteData().getInt32(0, Endian.host) != 0;
}

void main() {
  test('WITNESS: a socket accepted by the server has Nagle off', () async {
    Socket? accepted;
    final server = RpcHttp2Server(
      host: '127.0.0.1',
      port: 0,
      onConnectionOpened: (socket) => accepted ??= socket,
      onEndpointCreated: (e) => e.registerServiceContract(_Svc()),
    );
    await server.start();
    addTearDown(server.stop);

    final client = await RpcHttp2CallerTransport.connect(
      host: '127.0.0.1',
      port: server.port,
      logger: LogScope.noop,
    );
    final caller = RpcCallerEndpoint(transport: client);
    addTearDown(caller.close);

    // A real call, so the connection is fully established before reading.
    final response = await caller.unaryRequest<RpcString, RpcString>(
      serviceName: 'Svc',
      methodName: 'echo',
      request: 'x'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    );
    expect(response.value, 'x');

    expect(accepted, isNotNull);
    expect(
      readNoDelay(accepted!),
      isTrue,
      reason: 'every socket this server accepted had Nagle enabled',
    );
  });

  test('WITNESS: the helper the client paths call sets the option', () async {
    // The caller's own socket is not reachable from outside the transport, so
    // the client half is pinned at the helper the three connect paths call.
    final listener = await ServerSocket.bind('127.0.0.1', 0);
    addTearDown(listener.close);
    listener.listen((s) => s.destroy());

    final socket = await Socket.connect('127.0.0.1', listener.port);
    addTearDown(socket.destroy);

    expect(readNoDelay(socket), isFalse, reason: 'the dart:io default');
    disableNagle(socket);
    expect(readNoDelay(socket), isTrue);
  });

  test('GUARD: it never throws on a dead socket', () async {
    // Load-bearing: this now runs in the server's ACCEPT path, which is the
    // root zone, where an uncaught error kills the isolate. setOption on a
    // socket the peer has already reset is exactly the case that reaches it.
    final listener = await ServerSocket.bind('127.0.0.1', 0);
    addTearDown(listener.close);
    listener.listen((s) => s.destroy());

    final socket = await Socket.connect('127.0.0.1', listener.port);
    socket.destroy();

    expect(() => disableNagle(socket), returnsNormally);
  });

  test('GUARD: a burst of connections is all served', () async {
    // The option is now set on every accepted socket; a mistake there would
    // show up as connections that never get anywhere.
    final server = RpcHttp2Server(
      host: '127.0.0.1',
      port: 0,
      onEndpointCreated: (e) => e.registerServiceContract(_Svc()),
    );
    await server.start();
    addTearDown(server.stop);

    for (var i = 0; i < 5; i++) {
      final client = await RpcHttp2CallerTransport.connect(
        host: '127.0.0.1',
        port: server.port,
        logger: LogScope.noop,
      );
      final caller = RpcCallerEndpoint(transport: client);
      final response = await caller.unaryRequest<RpcString, RpcString>(
        serviceName: 'Svc',
        methodName: 'echo',
        request: 'call$i'.rpc,
        requestCodec: _codec,
        responseCodec: _codec,
      );
      expect(response.value, 'call$i');
      await caller.close();
    }
  });
}
