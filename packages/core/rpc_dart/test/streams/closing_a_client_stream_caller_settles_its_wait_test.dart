// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// close() on a ClientStreamCaller while finishSending() waits for the answer,
// with no deadline. close() cancelled the response subscription, and nothing
// else could settle the wait: it stayed pending forever, and the server was
// never told. Now the wait fails with RpcCancelledException and the server's
// handler is cancelled.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Slow extends RpcResponderContract {
  _Slow(this.cancelled) : super('Svc');

  final Completer<void> cancelled;

  @override
  void setup() {
    addClientStreamMethod<RpcString, RpcString>(
      methodName: 'c',
      handler: (requests, {RpcContext? context}) async {
        final all = await requests.toList();
        for (var i = 0; i < 50; i++) {
          if (context?.cancellationToken?.isCancelled ?? false) {
            if (!cancelled.isCompleted) cancelled.complete();
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        return 'n=${all.length}'.rpc;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

Future<(String, bool)> _call({required bool closeEarly}) async {
  final cancelled = Completer<void>();
  final (client, server) = RpcChannelTransport.memoryPair();
  final responder = RpcResponderEndpoint(transport: server)
    ..registerServiceContract(_Slow(cancelled))
    ..start();
  addTearDown(() async {
    await responder.close();
    await client.close();
  });
  final caller = ClientStreamCaller<RpcString, RpcString>(
    transport: client,
    serviceName: 'Svc',
    methodName: 'c',
    requestCodec: _codec,
    responseCodec: _codec,
  );
  await caller.send('a'.rpc);
  final outcome = caller.finishSending().then(
    (v) => 'value ${v.value}',
    onError: (Object e) => e.runtimeType.toString(),
  );
  if (closeEarly) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await caller.close();
  }
  final result = await outcome.timeout(
    const Duration(seconds: 2),
    onTimeout: () => 'STILL PENDING',
  );
  final serverTold = await cancelled.future
      .then((_) => true)
      .timeout(const Duration(milliseconds: 300), onTimeout: () => false);
  return (result, serverTold);
}

void main() {
  test('close() while finishSending() waits', () async {
    final (result, serverTold) = await _call(closeEarly: true);
    expect(result, 'RpcCancelledException');
    expect(serverTold, isTrue, reason: 'the handler is cancelled');
  });

  test('CONTROL: no close, the answer arrives', () async {
    final (result, serverTold) = await _call(closeEarly: false);
    expect(result, 'value n=1');
    expect(serverTold, isFalse);
  });
}
