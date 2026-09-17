// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The mirror of request_sink_bounds_its_producer_test, on the RESPONSE side.
//
// `responseSink`'s listener had no pause, so `addStream` never stopped pulling
// and a handler producing faster than the wire drains ran to exhaustion inside
// the server. Measured against a consumer that does not read, a 1 MB window and
// 16 KiB messages: 2000 of 2000 produced (31.3 MB), against 68 for
// ServerStreamResponder, which forwards pause through its relay.
//
// Polled to a threshold rather than counted after a fixed sleep: the handler's
// producer runs in this process.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

const int _offered = 2000;
const int _payload = 16 * 1024;

/// Generous against the 1 MB window (68 messages there), far below the 2000 an
/// unbounded pull reaches. One absolute bound, never a ratio between two runs.
const int _bound = 300;

void main() {
  test('WITNESS: responseSink does not drain its handler', () async {
    final (client, server) = RpcChannelTransport.pair(
      policy: const RpcSecurityPolicy(flowControlWindowBytes: 1024 * 1024),
    );

    // Built directly: responseSink is only reachable on the responder class.
    final responder = BidirectionalStreamResponder<RpcString, RpcString>(
      id: 1,
      transport: server,
      serviceName: 'Svc',
      methodName: 'firehose',
      requestCodec: _codec,
      responseCodec: _codec,
    );

    var produced = 0;
    final body = 'x' * _payload;
    Stream<RpcString> produce() async* {
      for (var i = 0; i < _offered; i++) {
        produced = i + 1;
        yield body.rpc;
      }
    }

    unawaited(
      responder.responseSink.addStream(produce()).catchError((Object _) {}),
    );

    final caller = BidirectionalStreamCaller<RpcString, RpcString>(
      transport: client,
      serviceName: 'Svc',
      methodName: 'firehose',
      requestCodec: _codec,
      responseCodec: _codec,
    );
    final sub = caller.responses.listen((_) {}, onError: (Object _) {});
    sub.pause();

    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while (DateTime.now().isBefore(deadline) && produced <= _bound) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }

    expect(
      produced,
      lessThanOrEqualTo(_bound),
      reason:
          'the responder pulled $produced of $_offered messages '
          '(${(produced * _payload / (1024 * 1024)).toStringAsFixed(1)} MB) '
          'out of the handler while the consumer was not reading. responseSink '
          'must pause its subscription for the duration of each send, as '
          'ServerStreamResponder does through its relay',
    );

    sub.resume();
    await sub.cancel();
    await responder.close().catchError((_) {});
    await caller.close().catchError((_) {});
    await client.close();
    await server.close();
  });

  test('GUARD: responseSink still delivers everything, in order', () async {
    final (client, server) = RpcChannelTransport.pair();

    final responder = BidirectionalStreamResponder<RpcString, RpcString>(
      id: 1,
      transport: server,
      serviceName: 'Svc',
      methodName: 'echo',
      requestCodec: _codec,
      responseCodec: _codec,
    );

    final caller = BidirectionalStreamCaller<RpcString, RpcString>(
      transport: client,
      serviceName: 'Svc',
      methodName: 'echo',
      requestCodec: _codec,
      responseCodec: _codec,
    );

    const total = 40;
    final seen = <String>[];
    final done = Completer<void>();
    caller.payloadResponses.listen((r) {
      seen.add(r.value);
      if (seen.length == total && !done.isCompleted) done.complete();
    }, onError: (Object _) {});

    for (var i = 0; i < total; i++) {
      responder.responseSink.add('$i'.rpc);
    }
    await responder.responseSink.close();

    await done.future.timeout(
      const Duration(seconds: 20),
      onTimeout: () =>
          fail('responseSink delivered ${seen.length} of $total messages'),
    );
    expect(seen, [for (var i = 0; i < total; i++) '$i']);

    await responder.close().catchError((_) {});
    await caller.close();
    await client.close();
    await server.close();
  });
}
