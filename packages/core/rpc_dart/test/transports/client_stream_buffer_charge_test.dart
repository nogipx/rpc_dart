// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A client-stream that carries a lot of data must not lose messages, and must
// never lose them in SILENCE.
//
// `_admitToStreamBuffer` charges every inbound message against
// `effectiveMaxBufferedBytes` and, over the bound, refuses it — with an early
// `return` that skips `_incoming.add(message)`, so the refused message reaches
// neither the per-stream controller nor the pipeline that feeds the handler.
// The only notice is an error pushed into that per-stream controller.
//
// For a client-stream nobody reads that controller: the pipeline feeds the
// handler directly (`_pipelineFedRequestStream` deliberately does not subscribe
// to `getMessagesForStream`). The charge is released only by `_fcMetered`,
// which is that same unused path — so the charge only grows.
//
// A consumer's upload of 17 messages arrived as 16, with no error on either
// side and a successful response over the missing one.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _CountingContract extends RpcResponderContract {
  _CountingContract() : super('Svc');

  int seen = 0;

  @override
  void setup() {
    addClientStreamMethod<RpcString, RpcString>(
      methodName: 'Collect',
      handler: (requests, {RpcContext? context}) async {
        await for (final _ in requests) {
          seen++;
        }
        return RpcString('$seen');
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

/// Runs one client-stream of [count] messages of [bytes] each and reports what
/// the handler received against what was sent.
Future<({String answer, int seen, Object? error})> _run({
  required int count,
  required int bytes,
  RpcSecurityPolicy policy = const RpcSecurityPolicy(),
}) async {
  final (client, server) = RpcChannelTransport.pair(policy: policy);
  final service = _CountingContract();
  final responder = RpcResponderEndpoint(transport: server);
  responder.registerServiceContract(service);
  responder.start();
  final caller = RpcCallerEndpoint(transport: client);

  final filler = 'x' * bytes;
  final requests = StreamController<RpcString>();
  final future = caller.clientStream<RpcString, RpcString>(
    serviceName: 'Svc',
    methodName: 'Collect',
    requestCodec: _codec,
    responseCodec: _codec,
  )(requests.stream);

  for (var i = 0; i < count; i++) {
    requests.add(RpcString('$i:$filler'));
  }
  await requests.close();

  String answer = '-';
  Object? error;
  try {
    answer = (await future.timeout(const Duration(seconds: 60))).value;
  } catch (e) {
    error = e;
  }
  await caller.close();
  await responder.close();
  await client.close();
  await server.close();
  return (answer: answer, seen: service.seen, error: error);
}

void main() {
  test('a client-stream past the per-stream bound keeps every message', () async {
    // 24 messages of 1 MB against a 16 MB bound: over it by half, and the
    // field's own shape — 17 frames of ~936 KB is 15.9 MB on one call.
    final r = await _run(count: 24, bytes: 1024 * 1024);

    expect(
      r.seen,
      24,
      reason: 'the handler was fed ${r.seen} of 24 — '
          'answer=${r.answer} error=${r.error}',
    );
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('and it is never silent about losing one', () async {
    // Tightened hard, so the bound is crossed on the third message. Whatever
    // the transport decides to do, the caller must not be told the call
    // succeeded over data the handler never saw.
    final r = await _run(
      count: 8,
      bytes: 512 * 1024,
      policy: const RpcSecurityPolicy(maxBufferedBytes: 1024 * 1024),
    );

    if (r.error == null) {
      expect(
        r.seen,
        8,
        reason: 'a successful call must mean the handler got everything; '
            'it got ${r.seen} of 8',
      );
    }
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('CONTROL: a small client-stream is unaffected', () async {
    final r = await _run(count: 8, bytes: 1024);
    expect(r.error, isNull);
    expect(r.seen, 8);
    expect(r.answer, '8');
  });
}
