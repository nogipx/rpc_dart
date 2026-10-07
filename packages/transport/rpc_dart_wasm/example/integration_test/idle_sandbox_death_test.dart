// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A sandbox that dies while the Kotlin driver is PARKED -- no timer pending, so
// nothing is being evaluated -- is reported to Dart, through the isolate's
// termination callback, and the next call fails at once instead of waiting
// out its deadline.
//
// MANUAL, and skipped by default: the sandbox process has to be killed from the
// host partway through. It runs under an isolated uid, so that needs root: a
// Play-image emulator refuses `kill`, `adb root`, `am kill` and `am force-stop`
// alike. Use a `google_apis` image, with a WebView new enough to compile WASM
// (installing the APK from an up-to-date device works). Run it as
//
//   fvm flutter test integration_test/idle_sandbox_death_test.dart \
//     -d <emulator> --dart-define=rpcWasmKillProbe=true
//
// and while it prints WINDOW-OPEN:
//
//   adb -s <emulator> root
//   adb -s <emulator> shell ps -A -o PID,NAME | grep js_sandbox
//   adb -s <emulator> shell kill -9 <pid>
@TestOn('vm')
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_wasm/rpc_dart_wasm.dart';

const _codec = RpcCodec(RpcString.fromJson);

/// Off unless asked for, because it cannot pass unattended.
const _enabled = bool.fromEnvironment('rpcWasmKillProbe');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'an idle runtime whose sandbox dies reports it',
    (_) async {
      final wasm = (await rootBundle.load(
        'assets/guest.wasm',
      )).buffer.asUint8List();
      final mjs = await rootBundle.loadString('assets/guest.mjs');
      final bridge = await RpcFlutterWasmBridge.load(
        wasmBytes: wasm,
        mjsCode: mjs,
      ).timeout(const Duration(seconds: 60));

      // A dead runtime is reported as an ERROR on `incoming`. Watch that
      // directly rather than inferring death from a call that did not answer:
      // the two have different fixes.
      Object? deathReported;
      var incomingClosed = false;
      final transport = RpcWasmTransport.fromBridge(
        bridge: bridge,
        isClient: true,
      );
      final caller = RpcCallerEndpoint(transport: transport);
      transport.incomingMessages.listen(
        (_) {},
        onError: (Object e) => deathReported ??= e,
        onDone: () => incomingClosed = true,
      );

      Future<String> say(String v, Duration budget) async {
        try {
          final r = await caller
              .unaryRequest<RpcString, RpcString>(
                serviceName: 'Echo',
                methodName: 'Say',
                request: v.rpc,
                requestCodec: _codec,
                responseCodec: _codec,
              )
              .timeout(budget);
          return r.value;
        } catch (e) {
          return 'ERR ${e.runtimeType}';
        }
      }

      // Prove the pipe works before anything is killed.
      final before = await say('a', const Duration(seconds: 10));
      // ignore: avoid_print
      print('PROBE before-kill call: $before');
      expect(before, 'echo:a');

      // No timers pending now, so the driver is parked. This is the state.
      // ignore: avoid_print
      print('PROBE WINDOW-OPEN: kill the sandbox process now (40 s)');
      final opened = DateTime.now();
      while (DateTime.now().difference(opened) < const Duration(seconds: 40)) {
        if (deathReported != null || incomingClosed) break;
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      // ignore: avoid_print
      print(
        'PROBE after-window  death: ${deathReported?.runtimeType ?? 'NONE'}  '
        'closed: $incomingClosed',
      );

      final clock = Stopwatch()..start();
      final after = await say('b', const Duration(seconds: 15));
      // ignore: avoid_print
      print(
        'PROBE after-kill call: $after  after ${clock.elapsedMilliseconds}ms  '
        'death: ${deathReported?.runtimeType ?? 'NONE'}  '
        'closed: $incomingClosed',
      );

      // The claim: a dead runtime is REPORTED, so a call fails fast instead of
      // waiting out its own budget.
      expect(
        deathReported ?? (incomingClosed ? 'closed' : null),
        isNotNull,
        reason:
            'the sandbox died and nothing told Dart, so every in-flight call '
            'waits out its deadline against a runtime that cannot answer',
      );

      await caller.close();
      await bridge.close();
    },
    skip: !_enabled,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
