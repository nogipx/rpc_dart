// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// `requestSink`'s listener had no pause, so `addStream` never stopped pulling:
// the caller drained the application's whole producer into _sendSequence,
// however slowly the peer consumed. Measured against a handler that takes one
// message and stalls, a 1 MB window and 16 KiB messages: 2000 of 2000 pulled
// (31.3 MB), against 66 for the sibling ClientStreamCaller.call(Stream), which
// pauses and therefore stops at the window.
//
// The bound is checked by POLLING to a threshold rather than by counting after
// a fixed sleep: the producer runs in this process, so a sleep says only how
// long the test waited.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

const int _offered = 2000;
const int _payload = 16 * 1024;

/// Generous against the 1 MB window (66 messages there), and far below the
/// 2000 an unbounded pull reaches. Both arms are checked against this one
/// absolute bound, never against each other as a ratio.
const int _bound = 300;

final class _StallContract extends RpcResponderContract {
  _StallContract() : super('Svc');

  @override
  void setup() {
    addBidirectionalMethod<RpcString, RpcString>(
      methodName: 'stall',
      handler: (reqs, {RpcContext? context}) async* {
        var n = 0;
        await for (final _ in reqs) {
          n++;
          if (n == 1) await Future<void>.delayed(const Duration(seconds: 10));
        }
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );

    addBidirectionalMethod<RpcString, RpcString>(
      methodName: 'echo',
      handler: (reqs, {RpcContext? context}) async* {
        await for (final r in reqs) {
          yield r;
        }
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

void main() {
  test('WITNESS: requestSink does not drain its producer', () async {
    final (client, server) = RpcChannelTransport.pair(
      policy: const RpcSecurityPolicy(flowControlWindowBytes: 1024 * 1024),
    );
    final responder = RpcResponderEndpoint(transport: server);
    responder.registerServiceContract(_StallContract());
    responder.start();

    final caller = BidirectionalStreamCaller<RpcString, RpcString>(
      transport: client,
      serviceName: 'Svc',
      methodName: 'stall',
      requestCodec: _codec,
      responseCodec: _codec,
    );
    caller.responses.listen((_) {}, onError: (Object _) {});

    var pulled = 0;
    final body = 'x' * _payload;
    Stream<RpcString> produce() async* {
      for (var i = 0; i < _offered; i++) {
        pulled = i + 1;
        yield body.rpc;
      }
    }

    unawaited(
      caller.requestSink.addStream(produce()).catchError((Object _) {}),
    );

    // Poll to the threshold: stop as soon as the bound is breached, so the test
    // fails on the defect rather than on how long it was willing to wait.
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while (DateTime.now().isBefore(deadline) && pulled <= _bound) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }

    expect(
      pulled,
      lessThanOrEqualTo(_bound),
      reason:
          'the caller pulled $pulled of $_offered messages '
          '(${(pulled * _payload / (1024 * 1024)).toStringAsFixed(1)} MB) out '
          'of the producer while the handler was stalled. requestSink must '
          'pause its subscription for the duration of each send, as '
          'ClientStreamCaller.call(Stream) does',
    );

    // NOT swallowed. This closes while `addStream(produce())` is still pulling
    // -- the producer is deliberately stalled -- and `StreamController.close()`
    // throws StateError in that state. A `.catchError((_) {})` here hid that
    // for as long as it was written.
    await caller.close();
    await responder.close();
    await client.close();
    await server.close();
  });

  test('GUARD: requestSink still delivers everything, in order', () async {
    final (client, server) = RpcChannelTransport.pair();
    final responder = RpcResponderEndpoint(transport: server);
    responder.registerServiceContract(_StallContract());
    responder.start();

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

    Stream<RpcString> produce() async* {
      for (var i = 0; i < total; i++) {
        yield '$i'.rpc;
      }
    }

    await caller.requestSink.addStream(produce());
    await caller.requestSink.close();

    await done.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () =>
          fail('requestSink delivered ${seen.length} of $total messages'),
    );
    expect(seen, [for (var i = 0; i < total; i++) '$i']);

    await caller.close();
    await responder.close();
    await client.close();
    await server.close();
  });
}
