// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A redirect is a refusal, never a second request.
//
// dart:io follows a 303 by itself, as a GET with an empty body, and sends
// every header the call carried except `authorization` to wherever the
// Location points -- `x-api-key` included. 301, 307 and 308 were already
// refused; a 303 is now refused the same way.

@TestOn('vm')
library;

import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http/rpc_dart_http.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

/// Calls a server that answers [status] with a Location on another origin;
/// returns what that origin received and the call's outcome.
Future<({List<String> seen, Object? error})> _redirectedBy(int status) async {
  final seen = <String>[];
  final other = await HttpServer.bind('127.0.0.1', 0);
  other.listen((r) async {
    seen.add('${r.method} x-api-key=${r.headers.value('x-api-key')}');
    await r.drain<void>();
    r.response.statusCode = 404;
    await r.response.close();
  });
  final redirecting = await HttpServer.bind('127.0.0.1', 0);
  redirecting.listen((r) async {
    await r.drain<void>();
    r.response.statusCode = status;
    r.response.headers.set('location', 'http://127.0.0.1:${other.port}/x');
    await r.response.close();
  });
  final caller = RpcCallerEndpoint(
    transport: RpcHttpCallerTransport(
      baseUrl: 'http://127.0.0.1:${redirecting.port}',
    ),
  );
  addTearDown(() async {
    await caller.close();
    await redirecting.close(force: true);
    await other.close(force: true);
  });

  Object? error;
  try {
    await caller.unary<RpcString, RpcString>(
      serviceName: 'Svc',
      methodName: 'echo',
      request: 'x'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
      context: RpcContext.withTimeout(
        const Duration(seconds: 3),
      ).withApiKey('secret'),
    );
  } catch (e) {
    error = e;
  }
  return (seen: seen, error: error);
}

void main() {
  test('WITNESS: a 303 is not followed to another origin', () async {
    final r = await _redirectedBy(303);
    expect(
      r.seen,
      isEmpty,
      reason: 'the call was re-sent where the 303 pointed, with its metadata',
    );
    expect(r.error, isA<RpcStatusException>());
  });

  // The statuses that were already refused stay refused.
  for (final status in [301, 307, 308]) {
    test('GUARD: a $status is not followed either', () async {
      final r = await _redirectedBy(status);
      expect(r.seen, isEmpty);
      expect(r.error, isA<RpcStatusException>());
    });
  }
}
