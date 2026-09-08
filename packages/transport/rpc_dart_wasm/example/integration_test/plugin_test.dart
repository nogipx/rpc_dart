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
import 'dart:io' show Platform;
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

  /// Boots [invokeMainBody] and waits for a console line containing [needle].
  Future<String> consoleAfterBoot(String invokeMainBody, String needle) async {
    final seen = Completer<String>();
    final all = <String>[];
    final bridge = await _boot(invokeMainBody: invokeMainBody);
    final sub = bridge.console.listen((line) {
      all.add(line);
      if (line.contains(needle) && !seen.isCompleted) seen.complete(line);
    });
    final outcome = await seen.future.timeout(
      const Duration(seconds: 8),
      onTimeout: () => 'NOTHING (saw: $all)',
    );
    await sub.cancel();
    await bridge.close();
    return outcome;
  }

  testWidgets('an error thrown in a guest timer reaches the host', (_) async {
    // Both platforms, by different routes: iOS runs due timers in
    // `_runDueTimers`, Android in `_tickAndReportNext`, and both wrap the
    // callback so the throw lands in console.error. This is the shape ordinary
    // guest code produces, which is why it is the cross-platform case.
    final line = await consoleAfterBoot(
      'setTimeout(function() { throw new Error("timer boom"); }, 200);',
      'timer boom',
    );

    expect(line, startsWith('E:'), reason: 'it is an error, not info');
  });

  testWidgets(
    'an uncaught error outside any handler reaches the host',
    (_) async {
      // WITNESS, iOS. `window.onerror` was added to report a throw during BOOT
      // and returns true, which suppresses the platform's own reporting -- but
      // once boot is answered `_rpcReportBoot` is a no-op, so a later uncaught
      // error was swallowed by the very hook meant to surface it.
      //
      // _nativeSetTimeout, not the polyfill: the timer runners above already
      // catch, so a throw there would prove nothing about THIS path.
      //
      // Android cannot reach this state and is not skipped out of convenience:
      // it is a bare V8 isolate with no event loop, so every entry into guest
      // code comes from the Kotlin driver through evaluateJavaScriptAsync and is
      // caught there. There is no "outside any handler" to test.
      final line = await consoleAfterBoot(
        '_nativeSetTimeout(function() { '
            'throw new Error("post-boot boom"); }, 200);',
        'post-boot boom',
      );

      expect(line, startsWith('E:'), reason: 'it is an error, not info');
      expect(line, contains('uncaught'));
    },
    skip: !Platform.isIOS,
  );

  testWidgets('an unhandled rejection after boot reaches the host', (_) async {
    // WITNESS, iOS. A Dart guest's unawaited failing Future surfaces as a
    // rejected promise, which is NOT an error event -- `window.onerror` never
    // sees it, so this needed its own handler.
    //
    // MEASURED AND OPEN ON ANDROID: the same guest there produces nothing.
    // JavaScriptSandbox gives a bare V8 isolate with no unhandledrejection
    // event and no host rejection callback, so the only way to see one is to
    // wrap Promise inside the guest -- which changes the semantics of every
    // promise a dart2wasm guest uses, and cannot be validated here without a
    // real .wasm fixture. Left to the owner rather than forced through.
    final line = await consoleAfterBoot(
      'Promise.reject(new Error("unawaited boom"));',
      'unawaited boom',
    );

    expect(line, startsWith('E:'));
    expect(line, contains('unhandled rejection'));
  }, skip: !Platform.isIOS);

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

  testWidgets('a boot failure names the actual reason', (_) async {
    // WITNESS, Android. The failure is reported from `_rpcWasmBootError`, which
    // is only ever set inside the boot IIFE's own catch -- so a script that
    // dies BEFORE reaching it left every field null, and that JSON was still a
    // non-null String, so it beat the real V8 message in `e.message`:
    //
    //   before : {"error":null,"trace":null,"phase":"init"}
    //   after  : Uncaught ReferenceError: rpcWasmReceiveBytes is not defined
    //
    // A guest author got a placeholder instead of the one line that says what
    // is wrong.
    Object? error;
    try {
      await RpcFlutterWasmBridge.load(
        wasmBytes: Uint8List.fromList([0, 1, 2, 3]),
        mjsCode: 'throw new Error("glue exploded");',
      ).timeout(const Duration(seconds: 45));
    } catch (e) {
      error = e;
    }

    expect(error, isNotNull, reason: 'a guest that throws must not boot');
    expect(
      '$error',
      contains('glue exploded'),
      reason: 'the reported reason must be the guest\'s, not a placeholder',
    );
    expect('$error', isNot(contains('"error":null')));
  });

  testWidgets(
    'bytes survive the round trip, across the size threshold',
    (_) async {
      // The plugin IS a byte pipe and no device test moved a byte through it
      // until now. Two ceilings are crossed here:
      //
      //  * Android splits host->guest at NAMED_DATA_THRESHOLD = 65536 --
      //    base64 below, provideNamedData above -- and neither branch had ever
      //    run.
      //  * 16 MiB is rpc_dart's own default maxMessageLengthBytes, so a guest
      //    may legally send one. WITNESS: guest->host leaves as the return
      //    value of evaluateJavaScriptAsync, capped at 20 MiB, and 16 MiB of
      //    base64 is 22.4 MB -- so it killed the whole runtime:
      //
      //      before : RpcStatusException(14) ... died: AssetFileDescriptor
      //               .getLength() should be <= 20971520
      //      after  : ok
      //
      //    iOS never had it: its byte path is raw, with no base64 expansion.
      final bridge = await RpcFlutterWasmBridge.load(
        wasmBytes: Uint8List.fromList([0, 1, 2, 3]),
        mjsCode: _echoGuest,
      ).timeout(const Duration(seconds: 45));

      final reader = _Inbox(bridge.incoming);

      for (final n in [
        1,
        1024,
        65535,
        65536,
        65537,
        262144,
        16 * 1024 * 1024,
      ]) {
        final sent = Uint8List.fromList(
          List<int>.generate(n, (i) => (i * 31 + 7) & 0xFF),
        );
        await bridge.send(sent);
        final got = await reader
            .take(n)
            .timeout(
              const Duration(seconds: 60),
              onTimeout: () => Uint8List(0),
            );
        expect(got, orderedEquals(sent), reason: 'round trip of $n bytes');
      }

      await reader.cancel();
      await bridge.close();
    },
    timeout: const Timeout(Duration(minutes: 8)),
  );
}

/// Boots without a real module and echoes every inbound frame straight back.
///
/// `globalThis.`, not a bare assignment: Android evaluates in strict mode, so a
/// bare one is an Uncaught ReferenceError there while iOS accepts it.
const _echoGuest = '''
globalThis.rpcWasmReceiveBytes = function(b) { _rpcWasmSendBytes(b); };
function compile(bytes) {
  return Promise.resolve({
    instantiate: function(imports) {
      return Promise.resolve({ invokeMain: function() {} });
    }
  });
}
''';

/// Accumulating reader; `package:async` is not a dependency here.
///
/// It ACCUMULATES on purpose. The bridge is a byte STREAM, not a message
/// boundary -- `RpcFrameMultiplexedChannel` above it reassembles frames across
/// chunks, and Android now hands the outbox back in bounded slices. Completing
/// on the first event would measure the chunk size rather than the round trip.
class _Inbox {
  _Inbox(Stream<Uint8List> source) {
    _sub = source.listen((v) {
      _buffer.add(v);
      _pump();
    });
  }

  late final StreamSubscription<Uint8List> _sub;
  final _buffer = BytesBuilder();
  int _want = 0;
  Completer<Uint8List>? _waiting;

  void _pump() {
    final c = _waiting;
    if (c == null || _buffer.length < _want) return;
    _waiting = null;
    final all = _buffer.takeBytes();
    c.complete(Uint8List.sublistView(all, 0, _want));
    if (all.length > _want) _buffer.add(Uint8List.sublistView(all, _want));
  }

  Future<Uint8List> take(int n) {
    final c = Completer<Uint8List>();
    _want = n;
    _waiting = c;
    _pump();
    return c.future;
  }

  Future<void> cancel() => _sub.cancel();
}
