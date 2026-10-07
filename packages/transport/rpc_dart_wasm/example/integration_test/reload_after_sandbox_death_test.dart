// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// After the Android JS sandbox process dies, a NEW runtime can still be loaded:
// the plugin must not keep handing out the dead sandbox.
//
// MANUAL, and skipped by default, for the reason idle_sandbox_death_test.dart
// gives: the sandbox has to be killed from the host while the test waits, and
// that needs root. Run it on a rootable emulator as
//
//   fvm flutter test integration_test/reload_after_sandbox_death_test.dart \
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

const _enabled = bool.fromEnvironment('rpcWasmKillProbe');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'a runtime loads after the sandbox died',
    (_) async {
      final wasm = (await rootBundle.load(
        'assets/guest.wasm',
      )).buffer.asUint8List();
      final mjs = await rootBundle.loadString('assets/guest.mjs');

      Future<(RpcFlutterWasmBridge, RpcCallerEndpoint)> open() async {
        final bridge = await RpcFlutterWasmBridge.load(
          wasmBytes: wasm,
          mjsCode: mjs,
        ).timeout(const Duration(seconds: 60));
        final caller = RpcCallerEndpoint(
          transport: RpcWasmTransport.fromBridge(
            bridge: bridge,
            isClient: true,
          ),
        );
        return (bridge, caller);
      }

      Future<String> say(RpcCallerEndpoint caller, String v) async {
        try {
          final r = await caller
              .unaryRequest<RpcString, RpcString>(
                serviceName: 'Echo',
                methodName: 'Say',
                request: v.rpc,
                requestCodec: _codec,
                responseCodec: _codec,
              )
              .timeout(const Duration(seconds: 15));
          return r.value;
        } catch (e) {
          return 'ERR $e';
        }
      }

      final (first, firstCaller) = await open();
      expect(await say(firstCaller, 'a'), 'echo:a');

      // ignore: avoid_print
      print('PROBE WINDOW-OPEN: kill the sandbox process now (40 s)');
      final opened = DateTime.now();
      while (!first.isClosed &&
          DateTime.now().difference(opened) < const Duration(seconds: 40)) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      // ignore: avoid_print
      print('PROBE first runtime closed: ${first.isClosed}');
      await firstCaller.close();
      await first.close();

      String second;
      try {
        final (bridge, caller) = await open();
        second = await say(caller, 'b');
        await caller.close();
        await bridge.close();
      } catch (e) {
        second = 'LOAD FAILED $e';
      }
      // ignore: avoid_print
      print('PROBE second runtime: $second');

      expect(second, 'echo:b');
    },
    skip: !_enabled,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
