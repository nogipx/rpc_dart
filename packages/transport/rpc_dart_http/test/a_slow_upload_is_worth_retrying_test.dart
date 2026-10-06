// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// `grpcStatusFromHttpStatus` keeps rows beyond grpc-go's table for the statuses
// rpc_dart's own responders emit. A status with no row is UNKNOWN, which the
// default retry predicate treats as final -- so the question each row has to
// answer is whether the condition behind it is transient. `bodyReadTimeout`'s
// 408 is: a stalled upload is the textbook transient failure.
//
// All three such rows are pinned together here, with the retry count beside
// each, because the status alone says nothing about what a caller does with it
// and retryability is the only thing the absent-row default gets wrong.

@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http/rpc_dart_http.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

/// A server answering every request with [httpStatus], counting what it got.
class _StatusServer {
  _StatusServer(this._server);

  final HttpServer _server;
  int requests = 0;

  int get port => _server.port;

  static Future<_StatusServer> start(int httpStatus) async {
    final server = await HttpServer.bind('127.0.0.1', 0);
    final answering = _StatusServer(server);
    server.forEach((request) async {
      answering.requests++;
      await request.drain<void>();
      request.response.statusCode = httpStatus;
      await request.response.close();
    }).ignore();
    return answering;
  }

  Future<void> stop() => _server.close(force: true);
}

/// The gRPC status a caller reports for [httpStatus], and how many requests the
/// server saw with the DEFAULT retry predicate attached.
Future<({int status, int requests})> _call(int httpStatus) async {
  final server = await _StatusServer.start(httpStatus);
  final transport = RpcHttpCallerTransport(
    baseUrl: 'http://127.0.0.1:${server.port}',
  );
  final caller = RpcCallerEndpoint(transport: transport)
    ..addInterceptor(
      RpcRetryInterceptor(
        maxAttempts: 3,
        backoff: const FixedBackoff(Duration(milliseconds: 1)),
      ),
    );
  addTearDown(() async {
    await caller.close();
    await transport.close();
    await server.stop();
  });

  var status = 0;
  try {
    await caller.unaryRequest<RpcString, RpcString>(
      serviceName: 'Svc',
      methodName: 'echo',
      request: 'x'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
      transferMode: RpcDataTransferMode.codec,
    );
    fail('a $httpStatus answer must not succeed');
  } on RpcStatusException catch (e) {
    status = e.statusCode;
  }
  return (status: status, requests: server.requests);
}

void main() {
  test('WITNESS a 408 is retried, not reported final', () async {
    final answered = await _call(408);

    expect(
      answered.status,
      RpcStatus.unavailable,
      reason: 'a body that did not arrive in time is a transient failure',
    );
    expect(
      answered.requests,
      3,
      reason: 'the default predicate retries UNAVAILABLE; UNKNOWN it does not',
    );
  });

  test('the responder really is what answers 408', () async {
    // The premise. Without it the row above is a table entry nothing produces.
    final transport = RpcHttpResponderTransport(
      bodyReadTimeout: const Duration(milliseconds: 100),
    );
    final responder = RpcResponderEndpoint(transport: transport)..start();
    final server = await shelf_io.serve(transport.handler, '127.0.0.1', 0);
    addTearDown(() async {
      await server.close(force: true);
      await responder.close();
      await transport.close();
    });

    // A raw socket, because `HttpClient` refuses to close a request that wrote
    // fewer bytes than its `content-length` -- the stall has to happen on the
    // wire, not in the client.
    final socket = await Socket.connect('127.0.0.1', server.port);
    addTearDown(socket.close);
    socket.write(
      'POST /Svc/echo HTTP/1.1\r\n'
      'Host: 127.0.0.1\r\n'
      'Content-Type: application/grpc\r\n'
      'Content-Length: 1024\r\n'
      '\r\n',
    );

    final answered = Completer<String>();
    final received = <int>[];
    socket.listen(
      (data) {
        received.addAll(data);
        final text = String.fromCharCodes(received);
        if (text.contains('\r\n\r\n') && !answered.isCompleted) {
          answered.complete(text);
        }
      },
      onDone: () {
        if (!answered.isCompleted) {
          answered.complete(String.fromCharCodes(received));
        }
      },
    );

    expect(
      await answered.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => fail('the responder never answered'),
      ),
      contains('408'),
    );
  });

  test(
    'the rows beyond the gRPC table and what each does to retries',
    () async {
      // 413 and 499 are the other two beyond grpc-go's table. 413 is emitted by
      // both responders for a body over the ceiling; 499 is nginx's, and no
      // rpc_dart responder sends it, so only the mapping is checked.
      expect(grpcStatusFromHttpStatus(408), RpcStatus.unavailable);
      expect(grpcStatusFromHttpStatus(413), RpcStatus.resourceExhausted);
      expect(grpcStatusFromHttpStatus(499), RpcStatus.cancelled);

      // RESOURCE_EXHAUSTED names a size the caller can reduce; with no pushback
      // it is final, because the same body fails the same way again.
      final tooLarge = await _call(413);
      expect(tooLarge.status, RpcStatus.resourceExhausted);
      expect(tooLarge.requests, 1);
    },
  );

  test('GUARD the statuses that must stay final still are', () async {
    // 405 and 415 are emitted by the HTTP/1.1 responder too, and deliberately
    // have no row: both are the caller's own bug, and `unknown` already makes
    // them final. This is the arm that fails if a row is added for the sake of a
    // nicer diagnostic without reading what it does to retries.
    for (final httpStatus in const [400, 405, 415]) {
      final answered = await _call(httpStatus);
      expect(
        answered.requests,
        1,
        reason: 'HTTP $httpStatus must not be retried',
      );
    }
  });

  test('GUARD the gRPC table rows are untouched', () {
    expect(grpcStatusFromHttpStatus(400), RpcStatus.internal);
    expect(grpcStatusFromHttpStatus(401), RpcStatus.unauthenticated);
    expect(grpcStatusFromHttpStatus(403), RpcStatus.permissionDenied);
    expect(grpcStatusFromHttpStatus(404), RpcStatus.unimplemented);
    expect(grpcStatusFromHttpStatus(429), RpcStatus.unavailable);
    expect(grpcStatusFromHttpStatus(502), RpcStatus.unavailable);
    expect(grpcStatusFromHttpStatus(503), RpcStatus.unavailable);
    expect(grpcStatusFromHttpStatus(504), RpcStatus.unavailable);
    // Off the table is UNKNOWN, not INTERNAL.
    expect(grpcStatusFromHttpStatus(405), RpcStatus.unknown);
    expect(grpcStatusFromHttpStatus(415), RpcStatus.unknown);
    expect(grpcStatusFromHttpStatus(418), RpcStatus.unknown);
  });
}
