// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The error details a handler throws reach the caller over HTTP/1.1, as they do
// on every other transport. They travel in `grpc-status-details-bin`, a header
// here, and the caller builds the status from the trailer frame -- so the
// header has to land in that frame with `grpc-status` and `grpc-message`.
//
// What depends on it: `RpcRetryInfo` is a detail, and the default retry
// predicate retries RESOURCE_EXHAUSTED only when it carries one.

@TestOn('vm')
library;

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_http/rpc_dart_http.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Svc extends RpcResponderContract {
  _Svc(this.onCall) : super('Svc');

  final void Function() onCall;

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'bad',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (r, {RpcContext? context}) async {
        onCall();
        throw RpcStatusException(
          RpcStatus.invalidArgument,
          'bad',
          details: [RpcErrorInfo(reason: 'WHY')],
        );
      },
    );
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'full',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (r, {RpcContext? context}) async {
        onCall();
        throw RpcStatusException.atCapacity('full');
      },
    );
  }
}

/// Calls [method] behind the default retry predicate; returns the caller's
/// exception and how many times the handler ran.
Future<({RpcStatusException error, int calls})> _call(String method) async {
  var calls = 0;
  final server = RpcHttpServer(
    host: '127.0.0.1',
    port: 0,
    onEndpointCreated: (e) {
      e.registerServiceContract(_Svc(() => calls++));
      e.start();
    },
  );
  await server.start();
  await server.afterModulesStart();
  final caller =
      RpcCallerEndpoint(
        transport: RpcHttpCallerTransport(
          baseUrl: 'http://127.0.0.1:${server.actualPort}',
        ),
      )..addInterceptor(
        RpcRetryInterceptor(
          maxAttempts: 3,
          backoff: const FixedBackoff(Duration(milliseconds: 1)),
        ),
      );
  addTearDown(() async {
    await caller.close();
    await server.stop();
  });

  try {
    await caller.unaryRequest<RpcString, RpcString>(
      serviceName: 'Svc',
      methodName: method,
      request: 'x'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    );
  } on RpcStatusException catch (e) {
    return (error: e, calls: calls);
  }
  throw StateError('$method must fail');
}

void main() {
  test('the details reach the caller', () async {
    final r = await _call('bad');
    expect(r.error.statusCode, RpcStatus.invalidArgument);
    expect(r.error.details.whereType<RpcErrorInfo>().map((d) => d.reason), [
      'WHY',
    ]);
  });

  test('a server at capacity is retried', () async {
    final r = await _call('full');
    expect(r.error.statusCode, RpcStatus.resourceExhausted);
    expect(r.calls, 3);
  });

  test('GUARD: a status without details is not retried', () async {
    final r = await _call('bad');
    expect(r.calls, 1);
  });
}
