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

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:rpc_dart_wasm/rpc_dart_wasm.dart';

/// A guest that boots WITHOUT a real WASM module.
///
/// The boot script calls bare globals `compileStreaming` (if defined) and
/// `compile`, then `instantiate({})` and `invokeMain()`. Supplying those in
/// plain JS reaches a booted runtime, which is what any test of post-boot
/// behaviour needs and what a `.wasm` fixture would otherwise cost.
String _fakeGuest({String invokeMainBody = ''}) =>
    '''
function compile(bytes) {
  return Promise.resolve({
    instantiate: function(imports) {
      return Promise.resolve({
        invokeMain: function() { $invokeMainBody }
      });
    }
  });
}
''';

Future<RpcFlutterWasmBridge> _boot({String invokeMainBody = ''}) =>
    RpcFlutterWasmBridge.load(
      wasmBytes: Uint8List.fromList([0, 1, 2, 3]),
      mjsCode: _fakeGuest(invokeMainBody: invokeMainBody),
    ).timeout(const Duration(seconds: 45));

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

  testWidgets('a guest boots at all', (_) async {
    // WITNESS. The page was loaded with `baseURL: nil`, i.e. an opaque origin,
    // and every byte path is a fetch of rpc-wasm:///. Those were therefore
    // cross-origin and WebKit blocked them, so boot died on its first line:
    //
    //   before : Failed to load WASM runtime: TypeError: Load failed
    //   after  : booted
    //
    // Nothing could see this before an example app existed to run the plugin.
    final bridge = await _boot();

    expect(bridge.isClosed, isFalse);
    await bridge.close();
  });

  testWidgets('a guest timer fires', (_) async {
    // WITNESS. `var _nativeSetTimeout = setTimeout;` sat in the same script as
    // `function setTimeout(...)`, and function declarations hoist -- so it
    // captured the POLYFILL. _scheduleNextTick then called itself and a single
    // guest setTimeout recursed until the stack blew:
    //
    //   before : nativeIsPolyfill=true,  no timer ever ran
    //   after  : nativeIsPolyfill=false, src=function setTimeout() { [native code
    //
    // Any Dart guest using Future.delayed or Timer was dead on iOS.
    final fired = Completer<String>();
    final bridge = await _boot(
      invokeMainBody:
          'setTimeout(function() { console.log("TIMER-FIRED"); }, 300);',
    );

    final sub = bridge.console.listen((line) {
      if (line.contains('TIMER-FIRED') && !fired.isCompleted) {
        fired.complete(line);
      }
    });

    final outcome = await fired.future.timeout(
      const Duration(seconds: 8),
      onTimeout: () => 'NEVER FIRED',
    );

    await sub.cancel();
    await bridge.close();

    expect(
      outcome,
      contains('TIMER-FIRED'),
      reason: 'the guest scheduled a 300 ms timer and it $outcome',
    );
  });

  testWidgets('glue code that throws is reported, not waited out', (_) async {
    // WITNESS. The boot script injects the guest's .mjs at TOP LEVEL, outside
    // the try/catch that guards instantiation. A throw there aborts the
    // <script> tag, so nothing ever posts to rpcBoot and the only thing left
    // is the 30 s watchdog. Measured on an iOS 18.6 simulator: 30051 ms
    // before, 275-961 ms after.
    final started = DateTime.now();
    await expectLater(
      RpcFlutterWasmBridge.load(
        wasmBytes: Uint8List.fromList([0, 1, 2, 3]),
        mjsCode: 'throw new Error("not a real module");',
      ).timeout(const Duration(seconds: 45)),
      throwsA(isA<StateError>()),
    );
    final ms = DateTime.now().difference(started).inMilliseconds;
    expect(
      ms,
      lessThan(15000),
      reason:
          'reported in ${ms}ms; a boot that cannot succeed must not cost the '
          'whole watchdog, which also holds a WKWebView per attempt',
    );
  });
}
