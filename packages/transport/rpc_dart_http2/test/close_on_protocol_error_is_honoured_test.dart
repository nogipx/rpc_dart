// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// `RpcSecurityPolicy.closeOnProtocolError` was read by RpcChannelTransport and
// by nothing else, so on HTTP/2 -- the transport a gRPC deployment actually
// exposes -- setting it did nothing at all. The peer was answered per stream
// and stayed connected to try again forever.
//
// A security knob that silently does nothing on two of five transports is
// worse than one that is absent, and this is the same class as round 119's
// `maxConcurrentHandlers` being inert on HTTP/1.1.
//
// The `:path` without a leading slash is what validateMetadata rejects and only
// a FOREIGN peer can send; rpc_dart's own caller always builds the path itself.
//
// Not implemented for rpc_dart_http on purpose: HTTP/1.1 there is
// request-scoped, so there is no connection to end that outliving the refusal
// would matter for.

@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:http2/http2.dart' as http2;
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Svc extends RpcResponderContract {
  _Svc() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'ping',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (r, {RpcContext? context}) async => 'pong'.rpc,
    );
  }
}

/// Sends [count] refused requests and reports whether the peer's connection
/// survived, plus how many were answered.
Future<({bool open, int answered})> _grind(
  int port,
  int count, {
  required String path,
}) async {
  final socket = await Socket.connect('127.0.0.1', port);
  final conn = http2.ClientTransportConnection.viaSocket(socket);
  var answered = 0;

  for (var i = 0; i < count; i++) {
    if (!conn.isOpen) break;
    final stream = conn.makeRequest([
      http2.Header.ascii(':method', 'POST'),
      http2.Header.ascii(':path', path),
      http2.Header.ascii(':scheme', 'http'),
      http2.Header.ascii(':authority', '127.0.0.1:$port'),
      http2.Header.ascii('content-type', 'application/grpc+proto'),
      http2.Header.ascii('te', 'trailers'),
    ], endStream: true);
    unawaited(
      stream.incomingMessages
          .drain<void>()
          .then((_) => answered++)
          .catchError((Object _) => answered),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }

  await Future<void>.delayed(const Duration(seconds: 1));
  final open = conn.isOpen;
  await conn.terminate().catchError((Object _) {});
  return (open: open, answered: answered);
}

Future<RpcHttp2Server> _serve(RpcSecurityPolicy policy) async {
  final server = RpcHttp2Server(
    host: '127.0.0.1',
    port: 0,
    securityPolicy: policy,
    onEndpointCreated: (e) => e.registerServiceContract(_Svc()),
  );
  await server.start();
  addTearDown(server.stop);
  return server;
}

void main() {
  test(
    'WITNESS: the flag ends the connection on HTTP/2',
    () async {
      // Pre-fix: open stayed true however many violations were sent.
      final server = await _serve(
        const RpcSecurityPolicy(closeOnProtocolError: true),
      );

      final r = await _grind(server.port, 5, path: 'Svc/ping');

      expect(
        r.open,
        isFalse,
        reason: 'the policy asked for the connection to end and it did not',
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'the refusal still reaches the peer first',
    () async {
      // Order matters: a plain disconnect reads as UNAVAILABLE and is RETRIED,
      // so the peer has to be told it was its own fault before the close.
      final server = await _serve(
        const RpcSecurityPolicy(closeOnProtocolError: true),
      );

      final r = await _grind(server.port, 1, path: 'Svc/ping');

      expect(r.answered, 1, reason: 'closed without answering');
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'GUARD: the default keeps the connection and answers',
    () async {
      // closeOnProtocolError defaults to false since round 190. Every violation
      // is answered and the connection carries on -- which is also what HTTP/2
      // did before the flag was honoured here at all.
      final server = await _serve(const RpcSecurityPolicy());

      final r = await _grind(server.port, 5, path: 'Svc/ping');

      expect(r.open, isTrue);
      expect(r.answered, 5);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'GUARD: a conforming peer is untouched by the flag',
    () async {
      // The close must fire on a POLICY violation, not on any error: a valid
      // request to a method that does not exist is an ordinary NOT_FOUND.
      final server = await _serve(
        const RpcSecurityPolicy(closeOnProtocolError: true),
      );

      final r = await _grind(server.port, 3, path: '/Svc/nope');

      expect(
        r.open,
        isTrue,
        reason: 'an unknown method is not a protocol violation',
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
