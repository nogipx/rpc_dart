// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A caller's cancel reason is the application's own text, and on every
// transport without a stream reset it travels in a header of the cancellation
// notice. A header value must be printable ASCII within maxHeaderValueBytes, so
// a reason in another language, or a long one, got the whole notice refused:
// the server never learned the call was cancelled. The reason is now
// percent-encoded, and replaced by a short one when even that does not fit.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

/// A server stream that ticks until cancelled and hands out its context.
final class _Svc extends RpcResponderContract {
  _Svc() : super('Svc');
  final context = Completer<RpcContext?>();

  @override
  void setup() {
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'Tick',
      handler: (r, {RpcContext? context}) {
        if (!this.context.isCompleted) this.context.complete(context);
        return Stream.periodic(
          const Duration(milliseconds: 20),
          (_) => 'tick'.rpc,
        );
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

/// Opens a ticking call, cancels it with [reason], and returns the reason the
/// server's token was cancelled with, or null if it was not within a second.
Future<String?> _serverReason(
  String reason, {
  RpcSecurityPolicy policy = const RpcSecurityPolicy(),
}) async {
  final (client, server) = RpcChannelTransport.memoryPair(policy: policy);
  final svc = _Svc();
  final responder = RpcResponderEndpoint(transport: server)
    ..registerServiceContract(svc)
    ..start();
  final caller = RpcCallerEndpoint(transport: client);
  addTearDown(() async {
    await caller.close();
    await responder.close();
  });

  final token = RpcCancellationToken();
  final first = Completer<void>();
  final sub = caller
      .serverStream<RpcString, RpcString>(
        serviceName: 'Svc',
        methodName: 'Tick',
        request: 'go'.rpc,
        requestCodec: _codec,
        responseCodec: _codec,
        context: RpcContext.empty().withCancellation(token),
      )
      .listen((_) {
        if (!first.isCompleted) first.complete();
      }, onError: (_) {});
  addTearDown(sub.cancel);
  await first.future;
  final serverToken = (await svc.context.future)!.cancellationToken!;

  token.cancel(reason);
  final reached = await Future.any([
    serverToken.cancelled.then((_) => true),
    Future<bool>.delayed(const Duration(seconds: 1), () => false),
  ]);
  return reached ? serverToken.reason : null;
}

void main() {
  test('a reason in another language reaches the server intact', () async {
    expect(
      await _serverReason('Пользователь отменил'),
      'Пользователь отменил',
      reason: 'null means the server never learned the call was cancelled',
    );
  });

  test('a reason past the header limit still cancels the server', () async {
    expect(
      await _serverReason(
        'x' * 200,
        policy: const RpcSecurityPolicy(maxHeaderValueBytes: 64),
      ),
      isNotNull,
      reason: 'the over-long reason got the whole notice refused',
    );
  });

  test('GUARD a plain ASCII reason arrives as it was sent', () async {
    expect(await _serverReason('user cancelled'), 'user cancelled');
  });
}
