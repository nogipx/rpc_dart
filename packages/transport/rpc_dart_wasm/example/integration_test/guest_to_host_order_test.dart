// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Do 10k frames from one guest stream arrive in the order the guest produced
// them?
//
// Ordering is not a nicety here: RpcChannelTransport reassembles a byte STREAM,
// so two frames swapped on the wire are not a reordered pair of messages, they
// are corruption -- the second frame's header is read from the middle of the
// first frame's payload.
//
// The two platforms guarantee it by different mechanisms, and only one of them
// is written down:
//
//   Android  the guest pushes into `_rpcWasmOutbox`, a JS array, and the driver
//            drains it in order. FIFO by construction.
//   iOS      `_rpcWasmSendBytes` does an UNAWAITED `fetch` per frame, so N are
//            in flight at once and the order the Swift scheme handler sees them
//            is WebKit's dispatch order -- conventional, not contractual.
//
// This test is platform-agnostic on purpose: it is the witness for both, and
// the iOS half is what would fail if that convention ever changed. See B-43.
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_wasm/rpc_dart_wasm.dart';

const _codec = RpcCodec(RpcString.fromJson);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    '10k frames from one guest stream arrive in order',
    (_) async {
      final wasm = (await rootBundle.load(
        'assets/guest.wasm',
      )).buffer.asUint8List();
      final mjs = await rootBundle.loadString('assets/guest.mjs');
      final bridge = await RpcFlutterWasmBridge.load(
        wasmBytes: wasm,
        mjsCode: mjs,
      ).timeout(const Duration(seconds: 60));
      final caller = RpcCallerEndpoint(
        transport: RpcWasmTransport.fromBridge(bridge: bridge, isClient: true),
      );

      const n = 10000;
      final clock = Stopwatch()..start();
      final got = await caller
          .serverStream<RpcString, RpcString>(
            serviceName: 'Echo',
            methodName: 'Count',
            request: '$n'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .map((e) => e.value)
          .toList()
          .timeout(const Duration(minutes: 5));

      // ignore: avoid_print
      print(
        'platform: ${Platform.operatingSystem}  '
        'frames: ${got.length}  elapsed: ${clock.elapsedMilliseconds}ms',
      );

      // Nothing lost: a reorder that also DROPS would pass an order check that
      // only compared neighbours.
      expect(got, hasLength(n));

      // The order itself. Compared against the generated sequence rather than
      // by scanning for inversions, so a swap, a duplicate and a gap are all
      // caught by the same assertion.
      expect(
        got,
        List<String>.generate(n, (i) => 'item-$i'),
        reason:
            'frames arrived out of order: the channel reassembles a byte '
            'stream, so this is corruption rather than a reordered pair',
      );

      await caller.close();
      await bridge.close();
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
