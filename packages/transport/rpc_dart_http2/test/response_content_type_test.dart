// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A 200 response whose content-type is not application/grpc* is not a gRPC
// response, and its body is not gRPC frames. The caller never checked, so the
// message parser met the raw bytes and failed on whatever the first one was:
// an HTML error page from a proxy came back as
//
//   RpcException: Invalid compression flag in gRPC message: 60
//
// -- 60 being '<'. That is not an RpcStatusException, so it carries no status
// code and callers that catch RpcStatusException miss it altogether, and the
// text names a framing detail rather than the actual problem.
//
// The responder pipeline has always applied this check in the other direction,
// with the same leniency: reject only when content-type is PRESENT and wrong.
// Absent is accepted, so a server that omits it keeps working -- being strict
// would be a new policy rather than a fix.

import 'dart:async';
import 'dart:io';

import 'package:http2/http2.dart' as http2;
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

Uint8List _framed(String text) =>
    RpcMessageFrame.encode(_codec.serialize(text.rpc), compressed: false);

/// Starts an HTTP/2 peer that answers every request with [reply].
Future<ServerSocket> _peer(
  void Function(http2.ServerTransportStream stream) reply,
) async {
  final socket = await ServerSocket.bind('127.0.0.1', 0);
  socket.listen((client) {
    final conn = http2.ServerTransportConnection.viaSocket(client);
    conn.incomingStreams.listen((stream) {
      stream.incomingMessages.listen((_) {}, onError: (Object _) {});
      reply(stream);
    }, onError: (Object _) {});
  }, onError: (Object _) {});
  return socket;
}

/// Makes one unary call and reports what came back.
Future<({String? value, Object? error})> _call(ServerSocket peer) async {
  final client = await RpcHttp2CallerTransport.connect(
    host: '127.0.0.1',
    port: peer.port,
  );
  final caller = RpcCallerEndpoint(transport: client);
  try {
    final r = await caller
        .unaryRequest<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: 'Echo',
          request: 'x'.rpc,
          requestCodec: _codec,
          responseCodec: _codec,
        )
        .timeout(const Duration(seconds: 10));
    return (value: r.value, error: null);
  } catch (e) {
    return (value: null, error: e);
  } finally {
    await caller.close();
    await client.close();
  }
}

/// Sends a well-formed OK response. Note the trailers carry no content-type,
/// which is correct and must not trip the check.
void _replyOk(http2.ServerTransportStream stream, {String? contentType}) {
  stream.sendHeaders([
    http2.Header.ascii(':status', '200'),
    if (contentType != null) http2.Header.ascii('content-type', contentType),
  ]);
  stream.sendData(_framed('pong'));
  stream.sendHeaders([http2.Header.ascii('grpc-status', '0')], endStream: true);
}

void main() {
  test('a 200 with a non-gRPC content-type fails as INTERNAL', () async {
    final peer = await _peer((stream) {
      stream.sendHeaders([
        http2.Header.ascii(':status', '200'),
        http2.Header.ascii('content-type', 'text/html'),
      ]);
      stream.sendData(
        Uint8List.fromList('<html>gateway error</html>'.codeUnits),
        endStream: true,
      );
    });
    addTearDown(peer.close);

    final result = await _call(peer);
    expect(
      result.error,
      isA<RpcStatusException>()
          .having((e) => e.statusCode, 'statusCode', RpcStatus.internal)
          .having((e) => e.message, 'message', contains('content-type')),
      reason:
          'without the check the body reached the gRPC frame parser and threw '
          'a bare RpcException naming a compression flag',
    );
  });

  test('a well-formed gRPC response still succeeds', () async {
    final peer = await _peer(
      (stream) => _replyOk(stream, contentType: 'application/grpc+proto'),
    );
    addTearDown(peer.close);

    expect((await _call(peer)).value, 'pong');
  });

  test('a response with no content-type at all still succeeds', () async {
    // GUARD against the stricter wrong fix. gRPC clients may reject this, but
    // the responder pipeline's own check treats absent as acceptable, and
    // tightening the client alone would break peers that omit the header.
    final peer = await _peer((stream) => _replyOk(stream));
    addTearDown(peer.close);

    expect((await _call(peer)).value, 'pong');
  });

  test('content-type parameters and casing are accepted', () async {
    // GUARD: the check is a case-insensitive prefix match, so the subtype and
    // any parameters a real peer appends must pass.
    final peer = await _peer(
      (stream) => _replyOk(
        stream,
        contentType: 'Application/GRPC+proto; charset=utf-8',
      ),
    );
    addTearDown(peer.close);

    expect((await _call(peer)).value, 'pong');
  });
}
