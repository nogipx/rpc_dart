// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A bidi caller whose request sink ERRORS, over a real isolate. Its channel is
// SendPort/ReceivePort and its frames are _IsolateMessages, so the notice takes
// a different route again.
//
// The worker reports through a unary call on the SAME transport: the responder
// lives in another isolate, so its counters are unreadable from here.
//
// Measured with the core notice ablated and restored:
//
//   erroring (ablated)   5 handlers still live      control   0
//   erroring (fixed)     0                          control   0

@TestOn('vm')
library;

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_isolate/rpc_dart_isolate.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Svc extends RpcResponderContract {
  _Svc() : super('Svc');

  int _live = 0;

  @override
  void setup() {
    addBidirectionalMethod<RpcString, RpcString>(
      methodName: 'echo',
      handler: (requests, {RpcContext? context}) async* {
        _live++;
        try {
          await for (final r in requests) {
            yield r;
          }
        } finally {
          _live--;
        }
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );

    addUnaryMethod<RpcString, RpcString>(
      methodName: 'live',
      handler: (r, {RpcContext? context}) async => '$_live'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

/// Top-level, as an isolate entrypoint must be.
void worker(IRpcTransport transport, Map<String, dynamic> params) {
  final responder = RpcResponderEndpoint(transport: transport);
  responder.registerServiceContract(_Svc());
  responder.start();
}

Stream<RpcString> _twoThenError() async* {
  yield 'a'.rpc;
  yield 'b'.rpc;
  throw StateError('producer died');
}

void main() {
  const calls = 5;

  late ({IRpcTransport transport, void Function() kill}) spawned;
  late RpcCallerEndpoint caller;

  setUp(() async {
    spawned = await RpcIsolateTransport.spawn(entrypoint: worker);
    caller = RpcCallerEndpoint(transport: spawned.transport);
  });

  tearDown(() async {
    await caller.close().catchError((_) {});
    spawned.kill();
  });

  BidirectionalStreamCaller<RpcString, RpcString> open() {
    final c = BidirectionalStreamCaller<RpcString, RpcString>(
      transport: spawned.transport,
      serviceName: 'Svc',
      methodName: 'echo',
      requestCodec: _codec,
      responseCodec: _codec,
    );
    c.responses.listen((_) {}, onError: (Object _) {});
    return c;
  }

  Future<String> live() async {
    final r = await caller
        .unaryRequest<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: 'live',
          request: '?'.rpc,
          requestCodec: _codec,
          responseCodec: _codec,
        )
        .timeout(const Duration(seconds: 10));
    return r.value;
  }

  // Polls rather than sleeping once: the teardown happens in the worker, so on
  // a loaded machine it is late rather than absent, while the leak this guards
  // against never clears at all.
  Future<void> expectNoneLive() async {
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    var last = '?';
    while (DateTime.now().isBefore(deadline)) {
      last = await live();
      if (last == '0') return;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    fail('$last handlers are still waiting on request streams that ended');
  }

  test('WITNESS: an erroring request sink stops the handler', () async {
    for (var i = 0; i < calls; i++) {
      final c = open();
      await c.requestSink.addStream(_twoThenError()).catchError((Object _) {});
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
    await expectNoneLive();
  });

  test('GUARD: the healthy half-close is unchanged', () async {
    for (var i = 0; i < calls; i++) {
      final c = open();
      c.requestSink.add('a'.rpc);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await c.requestSink.close();
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
    await expectNoneLive();
  });
}
