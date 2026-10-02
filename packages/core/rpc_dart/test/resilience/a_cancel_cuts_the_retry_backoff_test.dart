// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A call cancelled while the retry interceptor is backing off waited out the
// rest of the backoff before the next attempt noticed the token. Measured
// through the default jittered backoff the wait is random, which is how an
// earlier reading took it for prompt; a fixed backoff shows it.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Flaky extends RpcResponderContract {
  _Flaky() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'always',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (req, {context}) async =>
          throw RpcStatusException(RpcStatus.unavailable, 'try again'),
    );
  }
}

/// Status and elapsed milliseconds of one call with a fixed 3 s backoff,
/// cancelled after [cancelAfter] when given.
Future<(int, int)> _call({Duration? cancelAfter}) async {
  final (client, server) = RpcChannelTransport.pair();
  final responder = RpcResponderEndpoint(transport: server)
    ..registerServiceContract(_Flaky())
    ..start();
  final caller = RpcCallerEndpoint(transport: client)
    ..addInterceptor(
      RpcRetryInterceptor(
        maxAttempts: 2,
        backoff: const FixedBackoff(Duration(seconds: 3)),
      ),
    );
  final token = RpcCancellationToken();
  final sw = Stopwatch()..start();
  if (cancelAfter != null) {
    Timer(cancelAfter, () => token.cancel('not interested'));
  }
  var status = -1;
  try {
    await caller.unaryRequest<RpcString, RpcString>(
      serviceName: 'Svc',
      methodName: 'always',
      request: 'x'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
      context: RpcContext.withCancellation(token),
    );
  } on RpcStatusException catch (e) {
    status = e.statusCode;
  }
  final ms = sw.elapsedMilliseconds;
  await caller.close();
  await responder.close();
  return (status, ms);
}

void main() {
  test('a cancel during the backoff ends the call promptly', () async {
    final (status, ms) = await _call(
      cancelAfter: const Duration(milliseconds: 300),
    );
    expect(status, RpcStatus.cancelled);
    expect(ms, lessThan(1500), reason: 'waited out the backoff: $ms ms');
  });

  test('CONTROL: without a cancel the backoff is waited out', () async {
    final (status, ms) = await _call();
    expect(status, RpcStatus.unavailable);
    expect(ms, greaterThanOrEqualTo(3000));
  });
}
