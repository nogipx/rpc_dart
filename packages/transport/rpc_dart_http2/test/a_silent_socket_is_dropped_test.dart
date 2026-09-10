// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A TCP SYN used to buy an endpoint and a run of the application's callback.
//
// RpcHttp2Server._handleConnection is wired to the accept stream, so the
// transport, the endpoint and onEndpointCreated -- where contracts are
// registered -- were all built before the peer sent a byte. Every limit this
// server has is PER CONNECTION, so maxActiveStreams, maxConcurrentHandlers,
// halfOpenStreamTimeout and the pre-method budget are all downstream of a peer
// that never opens a stream, and nothing counted connections. Measured with 200
// sockets sending nothing:
//
//   prefaceTimeout off : endpoints 200, contracts disposed   1
//   prefaceTimeout on  : endpoints   0, contracts disposed 201
//
// against 0 and 0 on the websocket server, which builds an endpoint only for an
// already-upgraded connection.
//
// The deadline bounds traffic that never speaks HTTP/2 -- scanners, TLS probes,
// a stuck load balancer. It is NOT a defence against a determined attacker, who
// sends the 24 preface bytes and is then an idle conforming client; the third
// test pins that boundary so nobody mistakes one for the other.

@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

const int _sockets = 8;
const Duration _prefaceTimeout = Duration(milliseconds: 500);
const String _preface = 'PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n';

final class _Svc extends RpcResponderContract {
  _Svc() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'echo',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (r, {RpcContext? context}) async => r,
    );
  }
}

Future<RpcHttp2Server> _serve({required Duration? prefaceTimeout}) async {
  final server = RpcHttp2Server(
    host: '127.0.0.1',
    port: 0,
    prefaceTimeout: prefaceTimeout,
    onEndpointCreated: (e) => e.registerServiceContract(_Svc()),
  );
  await server.start();
  addTearDown(server.stop);
  return server;
}

/// Opens [count] sockets, optionally sending the HTTP/2 connection preface.
Future<List<Socket>> _open(int port, int count, {required bool speak}) async {
  final held = <Socket>[];
  for (var i = 0; i < count; i++) {
    final socket = await Socket.connect('127.0.0.1', port);
    // Drained so a server-side close surfaces as done rather than as pressure.
    socket.listen(null, onError: (_) {}, onDone: () {});
    if (speak) {
      socket.write(_preface);
      await socket.flush();
    }
    held.add(socket);
  }
  addTearDown(() {
    for (final socket in held) {
      socket.destroy();
    }
  });
  return held;
}

/// Polls [read] until it equals [want] or the budget runs out.
Future<int> _until(int Function() read, int want, Duration budget) async {
  final deadline = DateTime.now().add(budget);
  while (read() != want && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  return read();
}

void main() {
  test(
    'a socket that never speaks HTTP/2 is dropped',
    () async {
      // WITNESS. Pre-fix the endpoints stayed at 8 for as long as the peer held
      // the socket, and nothing counted them.
      final server = await _serve(prefaceTimeout: _prefaceTimeout);
      await _open(server.port, _sockets, speak: false);

      // Wait for the RISE first: "endpoints 0" would also pass on a server the
      // connections never reached.
      expect(
        await _until(
          () => server.endpoints.length,
          _sockets,
          const Duration(seconds: 5),
        ),
        _sockets,
        reason: 'every silent socket must first BE an endpoint',
      );

      expect(
        await _until(() => server.endpoints.length, 0, _prefaceTimeout * 10),
        0,
        reason: 'and then be dropped at the deadline',
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'GUARD: a peer that sends the preface is kept',
    () async {
      // The deadline must bound silence, not connections. Without this the
      // witness would pass on a server that dropped everything.
      final server = await _serve(prefaceTimeout: _prefaceTimeout);
      await _open(server.port, _sockets, speak: true);

      expect(
        await _until(
          () => server.endpoints.length,
          _sockets,
          const Duration(seconds: 5),
        ),
        _sockets,
      );
      await Future<void>.delayed(_prefaceTimeout * 4);
      expect(
        server.endpoints.length,
        _sockets,
        reason: 'speaking HTTP/2 disarms the deadline, and nothing else does',
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'GUARD: an ordinary call still works',
    () async {
      // The whole point is that a real client is untouched.
      final server = await _serve(prefaceTimeout: _prefaceTimeout);
      final caller = RpcCallerEndpoint(
        transport: await RpcHttp2CallerTransport.connect(
          host: '127.0.0.1',
          port: server.port,
        ),
      );
      addTearDown(caller.close);

      final response = await caller
          .unaryRequest<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'echo',
            request: 'hi'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .timeout(const Duration(seconds: 15));
      expect(response.value, 'hi');
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
