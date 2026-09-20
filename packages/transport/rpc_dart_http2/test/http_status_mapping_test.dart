// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A non-200 HTTP/2 `:status` was collapsed to gRPC INTERNAL, whatever it said.
// The mapping is normative (gRPC's doc/http-grpc-status-mapping.md, and the
// same table grpc-go applies whenever `:status` is not 200), and it decides
// real behaviour: RpcRetryInterceptor's default predicate retries only
// UNAVAILABLE and RESOURCE_EXHAUSTED.
//
// So the ordinary failure modes of anything sitting in front of a gRPC server
// -- 502, 503, 504, and 429 while rate limiting -- were permanently
// non-retryable, and 401 / 403 / 404 were hidden behind a generic INTERNAL.
//
// Measured, 9 statuses through a bare http2 peer:
//
//   before: 8 of 9 wrong (everything but 400, which really is INTERNAL)
//   after : 9 of 9 right
//   503 at maxAttempts 3: the peer saw 1 request  ->  3
//
// rpc_dart's own responder always sends `:status: 200`, so a non-200 only ever
// arrives from a foreign peer -- this is purely the interop path, which is why
// these tests speak to a raw http2 server rather than to RpcHttp2Server.

import 'dart:async';
import 'dart:io';

import 'package:http2/http2.dart' as http2;
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http2/rpc_dart_http2.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

/// A peer that answers every request with [httpStatus] and END_STREAM, and
/// counts the requests it received.
class _StatusPeer {
  _StatusPeer(this._socket);

  final ServerSocket _socket;
  int requests = 0;

  int get port => _socket.port;

  static Future<_StatusPeer> start(int httpStatus) async {
    final socket = await ServerSocket.bind('127.0.0.1', 0);
    final peer = _StatusPeer(socket);
    socket.listen((client) {
      final conn = http2.ServerTransportConnection.viaSocket(client);
      conn.incomingStreams.listen((stream) {
        peer.requests++;
        stream.incomingMessages.listen((_) {}, onError: (Object _) {});
        stream.sendHeaders([
          http2.Header.ascii(':status', '$httpStatus'),
        ], endStream: true);
      }, onError: (Object _) {});
    }, onError: (Object _) {});
    return peer;
  }

  Future<void> stop() => _socket.close();
}

/// Calls the peer once and returns the gRPC status the caller reported.
Future<int?> _statusSeenBy(
  _StatusPeer peer, {
  RpcRetryInterceptor? retry,
}) async {
  final client = await RpcHttp2CallerTransport.connect(
    host: '127.0.0.1',
    port: peer.port,
  );
  final caller = RpcCallerEndpoint(transport: client);
  if (retry != null) caller.addInterceptor(retry);

  int? seen;
  try {
    await caller
        .unaryRequest<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: 'Echo',
          request: 'x'.rpc,
          requestCodec: _codec,
          responseCodec: _codec,
        )
        .timeout(const Duration(seconds: 10));
  } on RpcStatusException catch (e) {
    seen = e.statusCode;
  } catch (_) {
    seen = null;
  }

  await caller.close();
  await client.close();
  return seen;
}

void main() {
  test('grpcStatusFromHttpStatus follows the gRPC mapping table', () {
    expect(grpcStatusFromHttpStatus(400), RpcStatus.internal);
    expect(grpcStatusFromHttpStatus(401), RpcStatus.unauthenticated);
    expect(grpcStatusFromHttpStatus(403), RpcStatus.permissionDenied);
    expect(grpcStatusFromHttpStatus(404), RpcStatus.unimplemented);
    expect(grpcStatusFromHttpStatus(429), RpcStatus.unavailable);
    expect(grpcStatusFromHttpStatus(502), RpcStatus.unavailable);
    expect(grpcStatusFromHttpStatus(503), RpcStatus.unavailable);
    expect(grpcStatusFromHttpStatus(504), RpcStatus.unavailable);
    // Anything off the table is UNKNOWN, not INTERNAL.
    expect(grpcStatusFromHttpStatus(418), RpcStatus.unknown);
    expect(grpcStatusFromHttpStatus(507), RpcStatus.unknown);
  });

  test('a caller reports the mapped status for a non-200 peer', () async {
    const cases = <int, int>{
      503: RpcStatus.unavailable,
      404: RpcStatus.unimplemented,
      401: RpcStatus.unauthenticated,
      418: RpcStatus.unknown,
      // Control: 400 really is INTERNAL, so it must not move.
      400: RpcStatus.internal,
    };

    for (final entry in cases.entries) {
      final peer = await _StatusPeer.start(entry.key);
      addTearDown(peer.stop);
      expect(
        await _statusSeenBy(peer),
        entry.value,
        reason: 'HTTP ${entry.key} must surface as gRPC status ${entry.value}',
      );
    }
  });

  test('a 503 is retried and a 400 is not', () async {
    RpcRetryInterceptor retry() => RpcRetryInterceptor(
      maxAttempts: 3,
      backoff: const ExponentialBackoff(
        baseDelay: Duration(milliseconds: 20),
        maxDelay: Duration(milliseconds: 50),
      ),
    );

    final unavailable = await _StatusPeer.start(503);
    addTearDown(unavailable.stop);
    await _statusSeenBy(unavailable, retry: retry());
    expect(
      unavailable.requests,
      3,
      reason:
          'UNAVAILABLE is what RetryInterceptor retries; collapsing 503 to '
          'INTERNAL made the textbook retryable failure permanent',
    );

    // Control: INTERNAL is not retryable, so this one must stay at one attempt
    // both before and after the fix -- otherwise the test is measuring the
    // interceptor rather than the mapping.
    final badRequest = await _StatusPeer.start(400);
    addTearDown(badRequest.stop);
    await _statusSeenBy(badRequest, retry: retry());
    expect(badRequest.requests, 1);
  });
}
