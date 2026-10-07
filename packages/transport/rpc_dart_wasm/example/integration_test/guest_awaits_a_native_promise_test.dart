// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A guest handler that awaits, 100 times in a row, a promise the JS engine
// resolves itself -- the shape of every browser API -- finishes at once.
//
// Each resumption runs in the engine's own microtask queue, and the Dart
// microtasks it schedules go through `queueMicrotask`. A boot script that
// replaces that function with a queue it drains only on a timer tick or an
// inbound frame parks them until one happens, which on an idle runtime is
// never. One await can slip through on a tick the call itself causes; a chain
// cannot.
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
    'a guest awaiting a native promise resumes',
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

      final clock = Stopwatch()..start();
      String answer;
      try {
        answer =
            (await caller
                    .unaryRequest<RpcString, RpcString>(
                      serviceName: 'Echo',
                      methodName: 'AfterPromise',
                      request: '100'.rpc,
                      requestCodec: _codec,
                      responseCodec: _codec,
                    )
                    .timeout(const Duration(seconds: 10)))
                .value;
      } catch (e) {
        answer = 'ERR ${e.runtimeType}';
      }
      // ignore: avoid_print
      print(
        'platform: ${Platform.operatingSystem}  answer: $answer  '
        'after ${clock.elapsedMilliseconds}ms',
      );

      expect(answer, startsWith('resumed 100 in'));
      expect(clock.elapsedMilliseconds, lessThan(2000));

      await caller.close();
      await bridge.close();
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
