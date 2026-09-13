// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// How late is a guest `Timer`?
//
// On iOS the guest runs in a WKWebView that is never added to a view hierarchy,
// so its page is permanently hidden -- and WebKit throttles timers in hidden
// pages. A guest whose Timers are delayed by seconds is a different product
// from one whose Timers are accurate: deadlines, keepalives, retry backoff and
// every `Future.delayed` in guest code ride on them.
//
// MEASURED INSIDE THE GUEST. A round trip through the bridge costs 3-31 ms
// (see frame_cost_test.dart), which is more than the delays being measured, so
// timing this from the host would report the transport rather than the timer.
// The guest clocks its own sleep and returns min,median,max lag in micros.
//
// Android's driver loop computes the next deadline and sleeps on it, so it is
// the control: whatever iOS does, Android shows what this guest's timers cost
// when nothing is throttling them.
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
    'a guest Timer is not throttled into uselessness',
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

      final rows = <String>[];
      var worstMedianMs = 0;
      for (final wanted in [1, 10, 100, 1000]) {
        final r = await caller
            .unaryRequest<RpcString, RpcString>(
              serviceName: 'Echo',
              methodName: 'TimerLag',
              request: '$wanted'.rpc,
              requestCodec: _codec,
              responseCodec: _codec,
            )
            .timeout(const Duration(minutes: 2));
        final parts = r.value.split(',').map(int.parse).toList();
        String ms(int micros) => '${(micros / 1000).toStringAsFixed(1)}ms';
        rows.add(
          '   ${'Timer($wanted ms)'.padRight(18)}'
          '${ms(parts[0]).padRight(10)}${ms(parts[1]).padRight(10)}'
          '${ms(parts[2])}',
        );
        final medianMs = (parts[1] / 1000).round();
        if (medianMs > worstMedianMs) worstMedianMs = medianMs;
      }

      // ignore: avoid_print
      print(
        'platform: ${Platform.operatingSystem}   (lag over the requested delay, '
        'n=10 each)\n'
        '   delay             min       median    max\n'
        '${rows.join("\n")}',
      );

      // The bar is deliberately loose: this pins "usable", not "precise". A
      // hidden-page throttle of the kind WebKit applies to background tabs
      // clamps timers to 1000 ms or worse, which this would catch; ordinary
      // scheduling jitter on a simulator would not.
      expect(
        worstMedianMs,
        lessThan(500),
        reason:
            'a guest Timer is late by ${worstMedianMs}ms at the median, so '
            'deadlines and backoff inside the guest cannot be trusted',
      );

      await caller.close();
      await bridge.close();
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
