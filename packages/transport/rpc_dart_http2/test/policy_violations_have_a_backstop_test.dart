// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// `closeOnProtocolError` defaults to false, which says one bad frame must not
// end the connection — not that a peer may grind forever.
// `RpcChannelTransport._validateInbound` has always carried a second mechanism
// for that, a 256-violation backstop, and its comment prices it: 200k violating
// frames cost 100 MiB of RSS with the connection still open to repeat it.
//
// http2 had the FIELD (responder, :412) and not the backstop, and the caller had
// neither. Measured at the default policy: 2000 violating header blocks all
// accepted, connection still open, RSS up 27 MiB, against a shared-layer
// control that closed after 256.
//
// The asymmetry between the two halves is deliberate and is why the caller gets
// ONLY the backstop: the library's position for a client is that killing the
// connection over one peer fault is the wrong answer because the other in-flight
// calls die with it (`closeOnOversizedFrame: !isClient`). A peer that has done
// it 256 times is no longer one bad frame.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:http2/http2.dart' as http2;
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

/// Past the 256 backstop with room for the overshoot that batching causes.
const int _pastTheBackstop = 1500;

final class _Svc extends RpcResponderContract {
  _Svc() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'Echo',
      handler: (r, {RpcContext? context}) async => r,
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

/// A request header block the default policy must refuse: 200 headers against
/// `maxHeaders` of 128, each header individually legal.
List<http2.Header> _violating() => [
  http2.Header.ascii(':method', 'POST'),
  http2.Header.ascii(':path', '/Svc/Echo'),
  http2.Header.ascii(':scheme', 'http'),
  http2.Header.ascii(':authority', '127.0.0.1'),
  http2.Header.ascii('content-type', 'application/grpc+proto'),
  for (var h = 0; h < 200; h++) http2.Header.ascii('x-h$h', 'v'),
];

/// Opens [count] violating streams and reports whether the connection survived.
Future<bool> grind(http2.ClientTransportConnection conn, int count) async {
  for (var i = 0; i < count; i++) {
    if (!conn.isOpen) return false;
    try {
      final stream = conn.makeRequest(_violating(), endStream: true);
      stream.incomingMessages.listen((_) {}, onError: (Object _) {});
    } catch (_) {
      return false;
    }
    if (i % 50 == 0) await Future<void>.delayed(Duration.zero);
  }
  await Future<void>.delayed(const Duration(seconds: 1));
  return conn.isOpen;
}

void main() {
  test(
    'a grinding peer loses the connection at the default policy',
    () async {
      // No closeOnProtocolError: the DEFAULT, which is the configuration this
      // has to hold under.
      final server = RpcHttp2Server(
        host: '127.0.0.1',
        port: 0,
        onEndpointCreated: (e) => e.registerServiceContract(_Svc()),
      );
      await server.start();
      addTearDown(server.stop);

      final socket = await Socket.connect('127.0.0.1', server.port);
      final conn = http2.ClientTransportConnection.viaSocket(socket);
      addTearDown(() async {
        try {
          await conn.terminate();
        } catch (_) {}
      });

      expect(
        await grind(conn, _pastTheBackstop),
        isFalse,
        reason:
            'the peer sent $_pastTheBackstop policy violations and kept its '
            'connection — nothing bounds what it can repeat',
      );
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );

  test(
    'GUARD: a few violations do not cost the connection',
    () async {
      // The backstop must not turn into closeOnProtocolError by the back door. A
      // misconfigured peer sending a handful of bad frames has to keep working,
      // which is the whole reason the field defaults to false.
      final server = RpcHttp2Server(
        host: '127.0.0.1',
        port: 0,
        onEndpointCreated: (e) => e.registerServiceContract(_Svc()),
      );
      await server.start();
      addTearDown(server.stop);

      final socket = await Socket.connect('127.0.0.1', server.port);
      final conn = http2.ClientTransportConnection.viaSocket(socket);
      addTearDown(() async {
        try {
          await conn.terminate();
        } catch (_) {}
      });

      expect(await grind(conn, 20), isTrue, reason: '20 is not hostile');

      // And it is still a working connection, not merely an open socket.
      final t = await RpcHttp2CallerTransport.connect(
        host: '127.0.0.1',
        port: server.port,
      );
      addTearDown(t.close);
      final caller = RpcCallerEndpoint(transport: t);
      addTearDown(caller.close);

      final reply = await caller
          .unaryRequest<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'Echo',
            request: 'x'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .timeout(const Duration(seconds: 10));
      expect(reply.value, 'x');
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );

  test(
    'a grinding SERVER loses the client transport too',
    () async {
      // The caller half got its own counter and needs its own witness. A hostile
      // server answers every request with a header block the client's policy
      // refuses; the client must stop talking to it.
      final listener = await ServerSocket.bind('127.0.0.1', 0);
      addTearDown(listener.close);

      listener.listen((socket) {
        final conn = http2.ServerTransportConnection.viaSocket(socket);
        conn.incomingStreams.listen((stream) {
          stream.incomingMessages.listen((_) {}, onError: (Object _) {});
          try {
            stream.sendHeaders([
              http2.Header.ascii(':status', '200'),
              http2.Header.ascii('content-type', 'application/grpc+proto'),
              // 200 response headers against the client's maxHeaders of 128.
              for (var h = 0; h < 200; h++) http2.Header.ascii('y-h$h', 'v'),
            ], endStream: true);
          } catch (_) {}
        }, onError: (Object _) {});
      }, onError: (Object _) {});

      final t = await RpcHttp2CallerTransport.connect(
        host: '127.0.0.1',
        port: listener.port,
      );
      addTearDown(() async {
        try {
          await t.close();
        } catch (_) {}
      });

      for (var i = 0; i < _pastTheBackstop; i++) {
        if (t.isClosed) break;
        try {
          final id = t.createStream();
          await t.sendMetadata(
            id,
            RpcMetadata.forClientRequest('Svc', 'Echo'),
            endStream: true,
          );
        } catch (_) {
          break;
        }
        if (i % 50 == 0) await Future<void>.delayed(Duration.zero);
      }
      await Future<void>.delayed(const Duration(seconds: 1));

      expect(
        t.isClosed,
        isTrue,
        reason:
            'the server answered $_pastTheBackstop calls with metadata the '
            'client refuses, and the client kept the connection',
      );
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );
}
