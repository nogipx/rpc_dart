// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The unary half of truncated_stream_without_trailers_test.
//
// gRPC requires every response to carry a grpc-status, in trailers or in a
// Trailers-Only response, so a stream that ends on DATA is malformed -- a proxy
// cutting the stream, or a server dying mid-response. Round 88 fixed the
// STREAMING shapes (a server stream ended on DATA is UNAVAILABLE) but left
// unary returning the value:
//
//   before : RETURNED "answer"   -- indistinguishable from a conforming reply
//   after  : UNAVAILABLE
//
// The caller could not tell a complete response from a truncated one, and acted
// on possibly-partial data.
//
// The cause was in core, not this transport: UnaryCaller completed its
// completer the instant a message decoded, so the UNAVAILABLE that the
// transport raises on a status-less end arrived after the call had returned and
// was discarded. It now holds the decoded value until a status actually
// arrives. The endpoint PING is unaffected -- it has its own implementation in
// caller_pipeline and never goes through UnaryCaller.

import 'dart:io';

import 'package:http2/http2.dart' as http2;
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

/// A raw HTTP/2 server answering one unary call, optionally omitting the
/// trailers that carry grpc-status.
Future<ServerSocket> _rawServer({required bool withTrailers}) async {
  final listener = await ServerSocket.bind('127.0.0.1', 0);
  listener.listen((socket) {
    final connection = http2.ServerTransportConnection.viaSocket(socket);
    connection.incomingStreams.listen((stream) {
      stream.incomingMessages.listen((_) {}, onError: (Object _) {});

      stream.sendHeaders([
        http2.Header.ascii(':status', '200'),
        http2.Header.ascii('content-type', 'application/grpc+proto'),
      ]);

      final framed = RpcMessageFrame.encode(_codec.serialize('answer'.rpc));
      stream.sendData(framed, endStream: !withTrailers);

      if (withTrailers) {
        stream.sendHeaders([
          http2.Header.ascii('grpc-status', '0'),
        ], endStream: true);
      }
    });
  });
  return listener;
}

Future<String> _call(int port) async {
  final transport = await RpcHttp2CallerTransport.connect(
    host: '127.0.0.1',
    port: port,
  );
  final caller = RpcCallerEndpoint(transport: transport);
  try {
    final r = await caller
        .unaryRequest<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: 'Ask',
          request: 'q'.rpc,
          requestCodec: _codec,
          responseCodec: _codec,
        )
        .timeout(const Duration(seconds: 20));
    return 'returned ${r.value}';
  } catch (e) {
    return e is RpcStatusException
        ? 'status ${e.statusCode}'
        : '${e.runtimeType}';
  } finally {
    await transport.close().catchError((Object _) {});
  }
}

void main() {
  test(
    'a unary response ended on DATA without trailers is an error',
    () async {
      final listener = await _rawServer(withTrailers: false);
      addTearDown(() => listener.close());

      expect(
        await _call(listener.port),
        'status ${RpcStatus.unavailable}',
        reason:
            'a response with no grpc-status is malformed; returning its value '
            'hands the caller possibly-truncated data as if it were complete',
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'GUARD: a conforming unary response still returns its value',
    () async {
      // The load-bearing guard: the value is now held until a status arrives,
      // so a well-formed response must still complete -- otherwise every unary
      // call would fail.
      final listener = await _rawServer(withTrailers: true);
      addTearDown(() => listener.close());

      expect(await _call(listener.port), 'returned answer');
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
