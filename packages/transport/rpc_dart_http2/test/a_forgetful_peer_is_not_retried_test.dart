// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A peer that answers and then ends the stream with NO trailers was reported
// UNAVAILABLE, which is exactly what `RpcRetryInterceptor` retries by design. The
// request had already reached a server that ran it, so the work was re-issued:
//
//     no trailers, maxAttempts 3   status 14, the server ran it 3 times
//     no trailers, no retry        status 14, the server ran it 1 time
//     trailers sent, maxAttempts 3 returned "ok", 1 time
//
// The COUNT is the finding; the status is only how the retry gets chosen. INTERNAL
// is grpc-go's answer for trailers that never came, and it keeps UNAVAILABLE for a
// connection that went away -- a split this transport makes on
// `goawayReceived || !isOpen`, so `server.stop()` mid-call stays retryable (see
// graceful_drain_on_stop_test, which requires that by name).
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:http2/http2.dart' as http2;
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

var _requests = 0;

/// Answers in full and, when [sendTrailers] is false, ends on the DATA frame with
/// no status at all -- a server bug, and the request has run by then.
Future<ServerSocket> _server({required bool sendTrailers}) async {
  final socket = await ServerSocket.bind('127.0.0.1', 0);
  socket.listen((client) {
    final conn = http2.ServerTransportConnection.viaSocket(client);
    conn.incomingStreams.listen((stream) {
      _requests++;
      stream.incomingMessages.listen((_) {}, onError: (Object _) {});
      stream.sendHeaders([
        http2.Header.ascii(':status', '200'),
        http2.Header.ascii('content-type', 'application/grpc+proto'),
      ]);
      final body = RpcMessageFrame.encode(
        _codec.serialize('ok'.rpc),
        compressed: false,
      );
      if (sendTrailers) {
        stream.sendData(body);
        stream.sendHeaders([
          http2.Header.ascii('grpc-status', '0'),
        ], endStream: true);
      } else {
        stream.sendData(body, endStream: true);
      }
    }, onError: (Object _) {});
  }, onError: (Object _) {});
  return socket;
}

/// One call. Returns (what the caller saw, how many times the server ran it).
Future<(String, int)> _call({
  required bool sendTrailers,
  required bool retry,
}) async {
  _requests = 0;
  final socket = await _server(sendTrailers: sendTrailers);
  final transport = await RpcHttp2CallerTransport.connect(
    host: '127.0.0.1',
    port: socket.port,
  );
  final caller = RpcCallerEndpoint(transport: transport);
  if (retry) {
    caller.addInterceptor(
      RpcRetryInterceptor(
        maxAttempts: 3,
        backoff: const ExponentialBackoff(
          baseDelay: Duration(milliseconds: 10),
        ),
      ),
    );
  }
  addTearDown(() async {
    await caller.close().catchError((Object _) {});
    await transport.close().catchError((Object _) {});
    await socket.close();
  });

  try {
    final r = await caller
        .unaryRequest<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: 'Charge',
          request: 'x'.rpc,
          requestCodec: _codec,
          responseCodec: _codec,
        )
        .timeout(const Duration(seconds: 15));
    return ('returned ${r.value}', _requests);
  } on RpcStatusException catch (e) {
    return ('status ${e.statusCode}', _requests);
  }
}

void main() {
  // WITNESS. Before: ('status 14', 3).
  test('a peer that forgets its trailers is not retried', () async {
    final (what, ran) = await _call(sendTrailers: false, retry: true);

    expect(
      ran,
      1,
      reason:
          'the request reached a server that RAN it; retrying re-issues '
          'work that may already have committed, which for a non-idempotent '
          'method is the whole of the damage',
    );
    expect(what, 'status ${RpcStatus.internal}');
  });

  // CONTROL. The same peer without the interceptor: one run either way, so the
  // witness's 1 is the retry not firing and not the call failing to go out.
  test('CONTROL: without the interceptor it runs once anyway', () async {
    final (what, ran) = await _call(sendTrailers: false, retry: false);

    expect(ran, 1);
    expect(what, 'status ${RpcStatus.internal}');
  });

  // CONTROL. A healthy response still succeeds with the interceptor attached, so
  // nothing above has disabled retries or broken the ordinary path.
  test('CONTROL: a peer that sends trailers still succeeds', () async {
    final (what, ran) = await _call(sendTrailers: true, retry: true);

    expect(ran, 1);
    expect(what, 'returned ok');
  });
}
