// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

/// A retry interceptor runs the stages below it once per attempt, and each
/// attempt starts from the context the retry itself was given: what an inner
/// interceptor made of the previous attempt is not the next attempt's input.
void main() {
  test('an inner interceptor sees the same context on every attempt', () async {
    final seen = await _run([_AppendHeader()], serverDelay: Duration.zero);

    expect(seen.attempts, 3);
    expect(seen.headers, ['a', 'a', 'a']);
  });

  test(
    'a per-attempt timeout below the retry does not cut its retries',
    () async {
      // The call has 10 s; each attempt has 300 ms and fails UNAVAILABLE after
      // 250 ms. Judged against the attempt's deadline, 50 ms remain and the
      // 100 ms backoff does not fit, so the retry would give up after one.
      final seen = await _run([
        _PerAttemptTimeout(const Duration(milliseconds: 300)),
      ], serverDelay: const Duration(milliseconds: 250));

      expect(seen.attempts, 3);
    },
  );
}

Future<({int attempts, List<String?> headers})> _run(
  List<IRpcInterceptor> inner, {
  required Duration serverDelay,
}) async {
  final (client, server) = RpcChannelTransport.memoryPair();
  final responder = RpcResponderEndpoint(transport: server);
  final caller = RpcCallerEndpoint(transport: client);
  addTearDown(caller.close);
  addTearDown(responder.close);

  var attempts = 0;
  final headers = <String?>[];
  responder.registerServiceContract(
    _AlwaysUnavailable((context) async {
      attempts++;
      headers.add(context?.getHeader('x-probe'));
      await Future<void>.delayed(serverDelay);
    }),
  );
  responder.start();

  caller.addInterceptor(
    RpcRetryInterceptor(
      maxAttempts: 3,
      backoff: const RpcFixedBackoff(Duration(milliseconds: 100)),
    ),
  );
  inner.forEach(caller.addInterceptor);

  await expectLater(
    caller.unary<_Empty, _Empty>(
      serviceName: 'Probe',
      methodName: 'Call',
      request: const _Empty(),
      requestCodec: _Empty.codec,
      responseCodec: _Empty.codec,
      context: RpcContext.empty().withTimeout(const Duration(seconds: 10)),
    ),
    throwsA(
      isA<RpcStatusException>().having(
        (e) => e.statusCode,
        'statusCode',
        RpcStatus.unavailable,
      ),
    ),
  );
  return (attempts: attempts, headers: headers);
}

final class _Empty implements IRpcSerializable {
  const _Empty();
  factory _Empty.fromJson(Map<String, dynamic> _) => const _Empty();
  @override
  Map<String, dynamic> toJson() => {};
  static RpcCodec<_Empty> get codec => RpcCodec(_Empty.fromJson);
}

final class _AlwaysUnavailable extends RpcResponderContract {
  _AlwaysUnavailable(this.onCall) : super('Probe');
  final Future<void> Function(RpcContext? context) onCall;

  @override
  void setup() {
    addUnaryMethod<_Empty, _Empty>(
      methodName: 'Call',
      handler: (request, {context}) async {
        await onCall(context);
        throw RpcStatusException(RpcStatus.unavailable, 'transient');
      },
      requestCodec: _Empty.codec,
      responseCodec: _Empty.codec,
    );
  }
}

/// Appends `a` to `x-probe`, as an interceptor adding metadata would.
final class _AppendHeader extends IRpcInterceptor {
  @override
  Future<TResponse> interceptUnary<TRequest, TResponse>(
    RpcCallInfo call,
    TRequest request,
    RpcUnaryNext<TRequest, TResponse> next,
  ) {
    final seen = call.context.getHeader('x-probe') ?? '';
    return next(
      call.context.withAdditionalHeaders({'x-probe': '${seen}a'}),
      request,
    );
  }
}

/// Gives each attempt [perAttempt] from when it starts.
final class _PerAttemptTimeout extends IRpcInterceptor {
  _PerAttemptTimeout(this.perAttempt);
  final Duration perAttempt;

  @override
  Future<TResponse> interceptUnary<TRequest, TResponse>(
    RpcCallInfo call,
    TRequest request,
    RpcUnaryNext<TRequest, TResponse> next,
  ) => next(call.context.withTimeout(perAttempt), request);
}
