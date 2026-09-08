// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A REAL dart2wasm guest running rpc_dart INSIDE the sandbox.
//
// plugin_test.dart drives the raw bridge with plain JS, which proves the byte
// pipe and nothing above it. This is the only test where the framing, flow
// control and contract machinery run on both sides of a device boundary --
// what an application actually does.
//
// The guest is built by tool/build_guest.sh, never committed: a checked-in
// .wasm goes stale the moment core changes and the test would then report on a
// guest nobody is shipping.

import 'dart:async';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_wasm/rpc_dart_wasm.dart';

const _codec = RpcCodec(RpcString.fromJson);

Future<({RpcFlutterWasmBridge bridge, RpcCallerEndpoint caller})>
_connect() async {
  final wasm = (await rootBundle.load(
    'assets/guest.wasm',
  )).buffer.asUint8List();
  final mjs = await rootBundle.loadString('assets/guest.mjs');

  final bridge = await RpcFlutterWasmBridge.load(
    wasmBytes: wasm,
    mjsCode: mjs,
  ).timeout(const Duration(seconds: 60));

  // The guest runs RpcWasm.run with isClient: false, so it takes even stream
  // ids; the host must take odd ones or every call would collide.
  final caller = RpcCallerEndpoint(
    transport: RpcWasmTransport.fromBridge(bridge: bridge, isClient: true),
  );
  return (bridge: bridge, caller: caller);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'closing during a stream RAISES, it does not end cleanly',
    (_) async {
      // WITNESS. Cancellation used to `await _sendCancellationToServer(...)`
      // before delivering the error to its own consumer, so a send that never
      // completed took the local error with it. Only wasm could reach it: only
      // its bridge send awaits a Flutter platform-channel reply, and close()
      // tears the transport down underneath that await.
      //
      //   websocket / isolate : RpcCancelledException
      //   wasm, before        : items=11 events=[DONE]   <- silent truncation
      //   wasm, after         : ERROR RpcCancelledException, then DONE
      //
      // A stream that ends cleanly is indistinguishable from one that
      // finished, so the consumer processed a truncated stream and moved on.
      final c = await _connect();
      final events = <String>[];
      var items = 0;
      c.caller
          .serverStream<RpcString, RpcString>(
            serviceName: 'Echo',
            methodName: 'Firehose',
            request: ''.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .listen(
            (_) => items++,
            onError: (Object e) => events.add('ERROR ${e.runtimeType}'),
            onDone: () => events.add('DONE'),
            cancelOnError: false,
          );

      await Future<void>.delayed(const Duration(milliseconds: 400));
      unawaited(c.caller.close());

      // POLLED, not slept. The thing being waited for is the CONSUMER
      // OBSERVING the cancellation, and load delays observation rather than
      // production -- a flat 4 s false-failed twice at load average 16 while
      // passing in isolation. The witness stays exactly as sharp: a genuinely
      // silent truncation never produces an error at all, so it drains the
      // whole budget and still fails.
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (events.isEmpty || !events.first.startsWith('ERROR')) {
        if (DateTime.now().isAfter(deadline)) break;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }

      expect(items, greaterThan(0), reason: 'the stream must have been live');
      expect(
        events.first,
        startsWith('ERROR'),
        reason: 'ended as $events; a clean end cannot be told from completion',
      );

      await c.bridge.close();
    },
    timeout: const Timeout(Duration(minutes: 8)),
  );

  testWidgets(
    'a unary call reaches a real guest and comes back',
    (_) async {
      final c = await _connect();

      final r = await c.caller
          .unaryRequest<RpcString, RpcString>(
            serviceName: 'Echo',
            methodName: 'Say',
            request: 'hello'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .timeout(const Duration(seconds: 30));

      expect(r.value, 'echo:hello');

      await c.caller.close();
      await c.bridge.close();
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );

  testWidgets(
    'a server stream arrives in order and completes',
    (_) async {
      final c = await _connect();

      final got = await c.caller
          .serverStream<RpcString, RpcString>(
            serviceName: 'Echo',
            methodName: 'Count',
            request: '25'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .map((e) => e.value)
          .toList()
          .timeout(const Duration(seconds: 60));

      expect(got, hasLength(25));
      expect(got.first, 'item-0');
      expect(got.last, 'item-24');

      await c.caller.close();
      await c.bridge.close();
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );

  testWidgets(
    'a response near the default message ceiling survives',
    (_) async {
      // 4 MiB from inside the guest, through the framing layer, over the native
      // bridge. On Android this crosses the bounded outbox drain added in round
      // 185, and it is the first time a frame that size has been REASSEMBLED
      // rather than echoed as opaque bytes.
      final c = await _connect();

      const n = 4 * 1024 * 1024;
      final r = await c.caller
          .unaryRequest<RpcString, RpcString>(
            serviceName: 'Echo',
            methodName: 'Big',
            request: '$n'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .timeout(const Duration(seconds: 120));

      expect(r.value.length, n);

      await c.caller.close();
      await c.bridge.close();
    },
    timeout: const Timeout(Duration(minutes: 8)),
  );

  testWidgets(
    'an orphaned guest failure is reported as an ERROR',
    (_) async {
      // WITNESS. An unawaited failing Future inside the guest -- the way
      // ordinary code drops an error by accident -- already reached the host,
      // but through dart2wasm's own uncaught handler, which PRINTS. Measured on
      // both platforms before RpcWasm.run guarded its zone:
      //
      //   before : I:Bad state: orphaned guest failure     <- info
      //   after  : E:Unhandled error in WASM guest: ...    <- error, with stack
      //
      // An operator filtering the console stream for errors saw nothing when a
      // handler inside the sandbox failed.
      final c = await _connect();
      final seen = Completer<String>();
      final all = <String>[];
      final sub = c.bridge.console.listen((l) {
        all.add(l);
        if (l.contains('orphaned guest failure') && !seen.isCompleted) {
          seen.complete(l);
        }
      });

      // The call itself SUCCEEDS; the failure happens afterwards, detached.
      final r = await c.caller
          .unaryRequest<RpcString, RpcString>(
            serviceName: 'Echo',
            methodName: 'Orphan',
            request: ''.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .timeout(const Duration(seconds: 30));
      expect(r.value, 'scheduled');

      final line = await seen.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () => 'NOTHING (saw: $all)',
      );

      expect(
        line,
        startsWith('E:'),
        reason: 'a failed handler must not arrive as info',
      );

      await sub.cancel();
      await c.caller.close();
      await c.bridge.close();
    },
    timeout: const Timeout(Duration(minutes: 8)),
  );

  testWidgets(
    'all four call shapes work against a real guest',
    (_) async {
      // Only unary and serverStream had ever run over this transport with real
      // contracts. Round 172 found a per-shape delivery matrix defect in core,
      // so two shapes never exercised is a gap, not a formality.
      final c = await _connect();

      final say = await c.caller.unaryRequest<RpcString, RpcString>(
        serviceName: 'Echo',
        methodName: 'Say',
        request: 'hi'.rpc,
        requestCodec: _codec,
        responseCodec: _codec,
      );
      expect(say.value, 'echo:hi');

      final counted = await c.caller
          .serverStream<RpcString, RpcString>(
            serviceName: 'Echo',
            methodName: 'Count',
            request: '3'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .map((e) => e.value)
          .toList();
      expect(counted, ['item-0', 'item-1', 'item-2']);

      final collected = await c.caller.clientStream<RpcString, RpcString>(
        serviceName: 'Echo',
        methodName: 'Collect',
        requestCodec: _codec,
        responseCodec: _codec,
      )(Stream.fromIterable(['a'.rpc, 'b'.rpc, 'c'.rpc]));
      expect(collected.value, '3:a,b,c');

      final mirrored = await c.caller
          .bidirectionalStream<RpcString, RpcString>(
            serviceName: 'Echo',
            methodName: 'Mirror',
            requests: Stream.fromIterable(['x'.rpc, 'y'.rpc]),
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .map((e) => e.value)
          .toList();
      expect(mirrored, ['back:x', 'back:y']);

      await c.caller.close();
      await c.bridge.close();
    },
    timeout: const Timeout(Duration(minutes: 8)),
  );

  testWidgets(
    'cancelling a stream stops the handler inside the guest',
    (_) async {
      // Round 97's shape: on http2 the reset never reached the handler and it
      // produced 404715 more messages. The guest counts what it yields and
      // serves the count over RPC, so the host can ask whether it actually
      // STOPPED -- the connection stays UP, since tearing it down would stop
      // the handler for unrelated reasons.
      final c = await _connect();

      Future<int> produced() async {
        final r = await c.caller
            .unaryRequest<RpcString, RpcString>(
              serviceName: 'Echo',
              methodName: 'Produced',
              request: ''.rpc,
              requestCodec: _codec,
              responseCodec: _codec,
            )
            .timeout(const Duration(seconds: 30));
        return int.parse(r.value);
      }

      var received = 0;
      final ready = Completer<void>();
      final sub = c.caller
          .serverStream<RpcString, RpcString>(
            serviceName: 'Echo',
            methodName: 'Firehose',
            request: ''.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .listen(
            (_) {
              received++;
              if (received == 5 && !ready.isCompleted) ready.complete();
            },
            onError: (Object _) {},
            cancelOnError: false,
          );

      await ready.future.timeout(const Duration(seconds: 60));
      await sub.cancel();

      final atCancel = await produced();
      await Future<void>.delayed(const Duration(seconds: 3));
      final later = await produced();

      // Without this the test passes vacuously on a guest whose handler never
      // ran at all: 0 more than 0 is also "it stopped".
      expect(
        atCancel,
        greaterThan(0),
        reason: 'the handler must have produced something before the cancel',
      );
      expect(
        later - atCancel,
        lessThan(50),
        reason:
            'the guest produced ${later - atCancel} more items in 3 s after '
            'the client cancelled; the stop never reached the handler',
      );

      await c.caller.close();
      await c.bridge.close();
    },
    timeout: const Timeout(Duration(minutes: 8)),
  );

  testWidgets(
    'closing while the guest is producing does not take the app down',
    (_) async {
      // Round 186 fixed a close with an INBOUND forward in flight, which
      // crashed the Android process. This is the other direction: close
      // straight through a live producer, with the outbound drain mid-evaluate.
      // Repeated with a moving close point, because the race only sometimes
      // lines up.
      for (var i = 0; i < 4; i++) {
        final c = await _connect();
        var got = 0;
        final ready = Completer<void>();
        final sub = c.caller
            .serverStream<RpcString, RpcString>(
              serviceName: 'Echo',
              methodName: 'Firehose',
              request: ''.rpc,
              requestCodec: _codec,
              responseCodec: _codec,
            )
            .listen(
              (_) {
                got++;
                if (got == 1 + i && !ready.isCompleted) ready.complete();
              },
              onError: (Object _) {},
              cancelOnError: false,
            );

        await ready.future.timeout(const Duration(seconds: 60));
        // No cancel first, on purpose.
        await c.bridge.close().timeout(const Duration(seconds: 20));
        await sub.cancel();
        await c.caller.close().timeout(const Duration(seconds: 20));
      }
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
