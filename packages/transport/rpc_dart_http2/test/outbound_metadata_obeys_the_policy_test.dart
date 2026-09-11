// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The security policy governs what a transport EMITS, not only what it accepts.
// `RpcChannelTransport.sendMetadata` has always validated outbound — websocket,
// wasm and isolate inherit it — and `rpc_dart_http` ported the check to both of
// its halves. http2 did not: its only `validateMetadata` was on the inbound
// path.
//
// It was not unchecked. `_headerValue` rejects non-printable-ASCII. But that is
// a hardcoded rule and not the configured one, so `maxHeaders`,
// `maxHeaderValueBytes` and the name/path checks were enforced in one direction
// only, on the one transport of five that does not get them from the shared
// layer. Measured under maxHeaders=32, maxHeaderValueBytes=64, all three
// violations below were ACCEPTED and went on the wire.

import 'dart:async';
import 'dart:io';

import 'package:http2/http2.dart' as http2;
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

const _tight = RpcSecurityPolicy(maxHeaders: 32, maxHeaderValueBytes: 64);

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

void main() {
  late RpcHttp2Server server;

  Future<RpcHttp2CallerTransport> caller({RpcSecurityPolicy policy = _tight}) =>
      RpcHttp2CallerTransport.connect(
        host: '127.0.0.1',
        port: server.port,
        policy: policy,
      );

  setUp(() async {
    server = RpcHttp2Server(
      host: '127.0.0.1',
      port: 0,
      securityPolicy: _tight,
      onEndpointCreated: (e) => e.registerServiceContract(_Svc()),
    );
    await server.start();
  });

  tearDown(() => server.stop());

  test('the caller refuses outbound metadata its policy forbids', () async {
    final t = await caller();
    addTearDown(t.close);

    // Each is a rule the shared layer enforces and http2 did not. The peer's
    // inbound check would have caught these one round trip later, as a status
    // on that stream; refusing locally names the rule and costs no round trip.
    final violations = <String, RpcMetadata>{
      'too many headers': RpcMetadata([
        for (var i = 0; i < 64; i++) RpcHeader('x-h$i', 'v'),
      ], methodPath: '/Svc/Echo'),
      'over-long value': RpcMetadata([
        RpcHeader('x-long', 'a' * 200),
      ], methodPath: '/Svc/Echo'),
      'invalid header name': RpcMetadata([
        RpcHeader('bad name', 'v'),
      ], methodPath: '/Svc/Echo'),
    };

    for (final entry in violations.entries) {
      await expectLater(
        t.sendMetadata(t.createStream(), entry.value),
        throwsArgumentError,
        reason: '${entry.key} was put on the wire',
      );
    }
  });

  test('the responder refuses outbound metadata its policy forbids', () async {
    // The responder half got the identical two lines and needs its own witness,
    // or only half the fix is watched. Built directly on a raw connection: the
    // server does the same at rpc_http2_server.dart:598, and going through the
    // server instead would test whatever trailer the library happens to build
    // rather than the check.
    final listener = await ServerSocket.bind('127.0.0.1', 0);
    addTearDown(listener.close);

    final serverSide = Completer<RpcHttp2ResponderTransport>();
    listener.listen((socket) {
      serverSide.complete(
        RpcHttp2ResponderTransport(
          connection: http2.ServerTransportConnection.viaSocket(socket),
          policy: _tight,
        ),
      );
    });

    final socket = await Socket.connect('127.0.0.1', listener.port);
    final client = http2.ClientTransportConnection.viaSocket(socket);
    addTearDown(() async {
      await client.finish();
    });

    final responder = await serverSide.future.timeout(
      const Duration(seconds: 10),
    );
    addTearDown(responder.close);

    // The id does not have to exist: validation runs BEFORE the stream lookup,
    // which is the point -- a frame the policy forbids must not reach the wire
    // whatever else is wrong with it.
    await expectLater(
      responder.sendMetadata(
        1,
        RpcMetadata([for (var i = 0; i < 64; i++) RpcHeader('x-h$i', 'v')]),
      ),
      throwsArgumentError,
      reason: 'the responder put 64 headers on the wire against a cap of 32',
    );
  });

  test('GUARD: an ordinary call is unaffected', () async {
    // The check must refuse only what the policy names. An ordinary request
    // carries a handful of system headers and has to keep working -- a first
    // measurement used maxHeaders=4, which is below that, and every call failed
    // inbound while looking like the violation had poisoned the connection.
    final t = await caller();
    addTearDown(t.close);
    final endpoint = RpcCallerEndpoint(transport: t);
    addTearDown(endpoint.close);

    final reply = await endpoint
        .unaryRequest<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: 'Echo',
          request: 'hello'.rpc,
          requestCodec: _codec,
          responseCodec: _codec,
        )
        .timeout(const Duration(seconds: 10));
    expect(reply.value, 'hello');
  });

  test('GUARD: a -bin header carrying base64 still passes', () async {
    // `_headerValue` exempts `-bin` keys from its ASCII rule; the POLICY does
    // not. That exemption is not a capability being removed here: the library
    // base64-encodes `-bin` values (metadata.dart:129) and base64 is printable
    // ASCII, while a RAW non-ASCII value already died one line later inside
    // `Header.ascii`. This pins that the ordinary binary path is untouched.
    final t = await caller();
    addTearDown(t.close);

    final details = RpcMetadata.forTrailer(
      RpcStatus.internal,
      message: 'boom',
      statusDetailsBin: Uint8List.fromList(List.generate(32, (i) => i)),
    );

    await expectLater(
      t.sendMetadata(t.createStream(), details),
      completes,
      reason: 'base64 details are printable ASCII and within the caps',
    );
  });
}
