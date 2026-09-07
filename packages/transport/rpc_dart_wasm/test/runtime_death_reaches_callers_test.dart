// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A WASM runtime that dies on its own must answer the calls it was serving.
//
// Four transports do this; WASM had no death signal at all. `RpcWasmBridge` is
// a byte pipe whose `incoming` only ended when the HOST closed it, and iOS's
// `webViewWebContentProcessDidTerminate` routed through `finishBoot`, which is
// a no-op once boot has completed -- so a jetsammed content process (the normal
// way a WKWebView dies) told Dart nothing. Android's driver loop logged the
// terminal exception and `break`ed, leaving the isolate in `runtimes`.
//
// Measured over the bridge pair, one unary call in flight:
//
//   runtime death, no signal : HANGS, no answer in 5 s
//   bridge.isClosed          : false
//   CONTROL, host closes     : RpcStatusException
//
// Nothing else bounds a call here: this transport has no keepalive, and
// `grpc-timeout` is optional.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_wasm/rpc_dart_wasm.dart';

import 'support/fake_wasm_bridge.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Svc extends RpcResponderContract {
  _Svc() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'Slow',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (r, {RpcContext? context}) async {
        await Future<void>.delayed(const Duration(days: 1));
        return 'never'.rpc;
      },
    );
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'Fast',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (r, {RpcContext? context}) async => 'pong'.rpc,
    );
    addServerStreamMethod<RpcString, RpcString>(
      methodName: 'Firehose',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (r, {RpcContext? context}) async* {
        var i = 0;
        while (true) {
          yield 'item-${i++}'.rpc;
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      },
    );
  }
}

({FakeWasmBridge host, RpcCallerEndpoint caller}) _rig() {
  final pair = FakeWasmBridge.pair();
  final guest = RpcResponderEndpoint(
    transport: RpcWasmTransport.fromBridge(
      bridge: pair.server,
      isClient: false,
    ),
  );
  guest.registerServiceContract(_Svc());
  guest.start();
  final caller = RpcCallerEndpoint(
    transport: RpcWasmTransport.fromBridge(bridge: pair.client, isClient: true),
  );
  return (host: pair.client, caller: caller);
}

void main() {
  test(
    'a unary call in flight is answered when the runtime dies',
    () async {
      // WITNESS: pre-fix this waited out the 5 s and reported HANGS.
      final rig = _rig();
      final call = rig.caller.unaryRequest<RpcString, RpcString>(
        serviceName: 'Svc',
        methodName: 'Slow',
        request: 'hi'.rpc,
        requestCodec: _codec,
        responseCodec: _codec,
      );

      await Future<void>.delayed(const Duration(milliseconds: 100));
      rig.host.killRuntime('content_process_terminated');

      await expectLater(
        call.timeout(const Duration(seconds: 5)),
        throwsA(isA<RpcStatusException>()),
      );
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'a server stream in flight is ended when the runtime dies',
    () async {
      // WITNESS: the stream stayed open forever, so `await for` never returned.
      final rig = _rig();
      final items = <String>[];
      final done = Completer<Object?>();
      rig.caller
          .serverStream<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'Firehose',
            request: 'go'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .listen(
            (v) => items.add(v.value),
            onError: (Object e) {
              if (!done.isCompleted) done.complete(e);
            },
            onDone: () {
              if (!done.isCompleted) done.complete(null);
            },
          );

      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(
        items,
        isNotEmpty,
        reason: 'the stream must be live before the kill',
      );
      rig.host.killRuntime();

      final outcome = await done.future.timeout(const Duration(seconds: 5));
      expect(
        outcome,
        isNotNull,
        reason: 'ended silently instead of with a cause',
      );
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'the bridge reports itself closed after the runtime dies',
    () async {
      // Otherwise a caller that checks before dialling reuses a dead bridge.
      final rig = _rig();
      expect(rig.host.isClosed, isFalse);
      rig.host.killRuntime();
      expect(rig.host.isClosed, isTrue);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'GUARD: a live runtime still serves calls',
    () async {
      // Pairs with the witnesses: the death path must not fire on its own, or
      // the first two tests would pass on a transport that failed everything.
      final rig = _rig();
      final r = await rig.caller
          .unaryRequest<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'Fast',
            request: 'hi'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .timeout(const Duration(seconds: 5));
      expect(r.value, 'pong');
      expect(rig.host.isClosed, isFalse);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
