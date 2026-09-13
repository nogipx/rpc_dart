// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// What one RPC over this bridge COSTS, so the README can say it.
//
// The number people need before choosing this transport is not throughput, it
// is per-call latency: every frame crosses a process boundary (a Binder round
// trip into the JavaScriptSandbox on Android, a fetch through a scheme handler
// on iOS) and then a driver tick. A guess is worth nothing here, and the README
// currently gives none.
//
// Round-trip is measured, not one-way: it is what a caller experiences and the
// only thing measurable without clocks on both sides of the boundary.
//
// A WARM-UP round is discarded. The first call pays sandbox and isolate setup
// that no later call pays, and folding it into the median would describe a cost
// nobody sees twice.
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter/services.dart';
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
  final caller = RpcCallerEndpoint(
    transport: RpcWasmTransport.fromBridge(bridge: bridge, isClient: true),
  );
  return (bridge: bridge, caller: caller);
}

String _stats(List<int> micros) {
  final sorted = [...micros]..sort();
  String at(double q) =>
      '${(sorted[(sorted.length * q).clamp(0, sorted.length - 1).toInt()] / 1000).toStringAsFixed(1)}ms';
  return '${at(0.5).padRight(9)}${at(0.95).padRight(9)}${at(0.99)}';
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'what a call over the wasm bridge costs',
    (_) async {
      final c = await _connect();

      Future<int> once(String method, String arg) async {
        final clock = Stopwatch()..start();
        await c.caller
            .unaryRequest<RpcString, RpcString>(
              serviceName: 'Echo',
              methodName: method,
              request: arg.rpc,
              requestCodec: _codec,
              responseCodec: _codec,
            )
            .timeout(const Duration(seconds: 60));
        return clock.elapsedMicroseconds;
      }

      // Discarded: sandbox and isolate setup that no later call pays.
      await once('Say', 'warmup');

      final rows = <String>[];
      for (final (label, method, arg, n) in <(String, String, String, int)>[
        ('empty unary', 'Say', 'x', 200),
        ('1 KiB response', 'Big', '1024', 200),
        ('64 KiB response', 'Big', '65536', 100),
        ('1 MiB response', 'Big', '1048576', 20),
      ]) {
        final samples = <int>[];
        for (var i = 0; i < n; i++) {
          samples.add(await once(method, arg));
        }
        rows.add(
          '   ${label.padRight(18)}${'n=$n'.padRight(8)}'
          '${_stats(samples)}',
        );
      }

      // ignore: avoid_print
      print(
        'platform: ${Platform.operatingSystem}\n'
        '   shape             n       p50      p95      p99\n'
        '${rows.join("\n")}',
      );

      await c.caller.close();
      await c.bridge.close();
    },
    timeout: const Timeout(Duration(minutes: 15)),
  );
}
