// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The only tests that run the plugin's NATIVE code.
//
// `melos run test:wasm` drives the Dart bridge against a mocked
// BinaryMessenger, so it proves how Dart REACTS to a platform message and
// nothing about whether native ever sends one. `melos run analyze:native`
// proves both native files compile. Neither executes a line of Swift or
// Kotlin. These do, on a simulator or emulator.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:rpc_dart_wasm/rpc_dart_wasm.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('checkSupport round-trips through the platform channel', (
    _,
  ) async {
    // A method channel answered by real Swift/Kotlin. A wrong channel name, a
    // missing registration or a native throw all land here and nowhere else.
    final info = await RpcFlutterWasmBridge.checkSupport();

    expect(
      info.jsEngineAvailable,
      isTrue,
      reason: 'both platforms report a JS engine; false means native never ran',
    );
    expect(
      info.details,
      isNotEmpty,
      reason:
          'the details map is built natively, so an empty one is a '
          'round-trip that returned the Dart-side default',
    );
  });

  testWidgets('glue code that throws is reported, not waited out', (_) async {
    // The boot script injects the guest's .mjs at TOP LEVEL, outside the
    // try/catch that guards instantiation. A throw there aborts the <script>
    // tag, so nothing ever posts to rpcBoot and the only thing left is the
    // 30 s watchdog. Measured on an iOS 18.6 simulator: 31 s before.
    final started = DateTime.now();
    await expectLater(
      RpcFlutterWasmBridge.load(
        wasmBytes: Uint8List.fromList([0, 1, 2, 3]),
        mjsCode: 'throw new Error("not a real module");',
      ).timeout(const Duration(seconds: 45)),
      throwsA(isA<StateError>()),
    );
    final ms = DateTime.now().difference(started).inMilliseconds;
    // ignore: avoid_print
    print('BOOT-FAILURE-MS $ms');
    expect(
      ms,
      lessThan(15000),
      reason:
          'reported in ${ms}ms; a boot that cannot succeed must not cost the '
          'whole watchdog, which also holds a WKWebView per attempt',
    );
  });
}
