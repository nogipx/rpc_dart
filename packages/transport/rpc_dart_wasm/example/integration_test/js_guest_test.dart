// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The SAME guest as rpc_guest_test, compiled to JavaScript and run by the macOS
// plugin in a JavaScriptCore context of its own (`RpcFlutterWasmBridge.loadJs`).
//
// A bare JavaScriptCore has none of what dart2js expects of a page -- timers,
// microtasks scheduled by `self.scheduleImmediate`, `crypto`, `performance`,
// `console` -- so the environment the plugin installs is what is under test as
// much as the byte pipe: a guest whose Futures resumed late, or whose Timers
// fired out of order, would still pass a test that only echoes.
//
// Run on macOS: `fvm flutter test integration_test/js_guest_test.dart -d macos`
// (after tool/build_guest.sh). On iOS and Android, where the plugin runs WASM
// guests, every test here is skipped.

import 'dart:io' show Platform;

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_wasm/rpc_dart_wasm.dart';

const _codec = RpcCodec(RpcString.fromJson);

Future<({RpcFlutterWasmBridge bridge, RpcCallerEndpoint caller})> _connect({
  List<RpcJsScript> scripts = const [],
}) async {
  final code = await rootBundle.loadString('assets/guest.js');
  final bridge = await RpcFlutterWasmBridge.loadJs(
    code: code,
    scripts: scripts,
  ).timeout(const Duration(seconds: 30));
  // The guest takes even stream ids (isClient: false); the host odd ones.
  final caller = RpcCallerEndpoint(
    transport: RpcWasmTransport.fromBridge(bridge: bridge, isClient: true),
  );
  return (bridge: bridge, caller: caller);
}

Future<String> _say(
  RpcCallerEndpoint caller,
  String method, [
  String value = '',
]) async => (await caller.unary<RpcString, RpcString>(
  serviceName: 'Echo',
  methodName: method,
  request: value.rpc,
  requestCodec: _codec,
  responseCodec: _codec,
  context: RpcContext.empty().withTimeout(const Duration(seconds: 20)),
)).value;

/// A test of the macOS plugin; skipped elsewhere.
void _onMac(String description, WidgetTesterCallback body) =>
    testWidgets(description, body, skip: !Platform.isMacOS);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  _onMac('macOS runs a JS guest and no WASM one', (_) async {
    final support = await RpcFlutterWasmBridge.checkSupport();
    expect(support.canRunJsGuest, isTrue);
    expect(support.canRunDartWasm, isFalse);
    await expectLater(
      RpcFlutterWasmBridge.load(wasmBytes: Uint8List(0), mjsCode: ''),
      throwsA(isA<RpcStatusException>()),
    );
  });

  _onMac('a unary call round-trips through the guest', (_) async {
    final c = await _connect();
    addTearDown(() async {
      await c.caller.close();
      await c.bridge.close();
    });
    expect(await _say(c.caller, 'Say', 'hi'), 'echo:hi');
  });

  _onMac('all four shapes run', (_) async {
    final c = await _connect();
    addTearDown(() async {
      await c.caller.close();
      await c.bridge.close();
    });
    final items = await c.caller
        .serverStream<RpcString, RpcString>(
          serviceName: 'Echo',
          methodName: 'Count',
          request: '50'.rpc,
          requestCodec: _codec,
          responseCodec: _codec,
        )
        .map((r) => r.value)
        .toList();
    expect(items, [for (var i = 0; i < 50; i++) 'item-$i']);
    final collected = await c.caller.clientStream<RpcString, RpcString>(
      serviceName: 'Echo',
      methodName: 'Collect',
      requests: Stream.fromIterable(['a'.rpc, 'b'.rpc, 'c'.rpc]),
      requestCodec: _codec,
      responseCodec: _codec,
    );
    expect(collected.value, '3:a,b,c');
    final mirrored = await c.caller
        .bidirectionalStream<RpcString, RpcString>(
          serviceName: 'Echo',
          methodName: 'Mirror',
          requests: Stream.fromIterable(['x'.rpc, 'y'.rpc]),
          requestCodec: _codec,
          responseCodec: _codec,
        )
        .map((r) => r.value)
        .toList();
    expect(mirrored, ['back:x', 'back:y']);
  });

  _onMac('a Future resumed by the engine itself is not held for a tick', (
    _,
  ) async {
    final c = await _connect();
    addTearDown(() async {
      await c.caller.close();
      await c.bridge.close();
    });
    expect(
      await _say(c.caller, 'AfterPromise', '100'),
      startsWith('resumed 100'),
    );
  });

  _onMac('timers fire in deadline order, with their microtasks first', (
    _,
  ) async {
    final c = await _connect();
    addTearDown(() async {
      await c.caller.close();
      await c.bridge.close();
    });
    expect(await _say(c.caller, 'TimerOrder'), 'early,micro,same,late');
  });

  _onMac('a guest Timer is not late by more than a few ms', (_) async {
    final c = await _connect();
    addTearDown(() async {
      await c.caller.close();
      await c.bridge.close();
    });
    for (final ms in [1, 10, 100, 1000]) {
      final lag = await _say(c.caller, 'TimerLag', '$ms');
      final median = int.parse(lag.split(',')[1]);
      // ignore: avoid_print
      print('Timer($ms ms) lag min,median,max us: $lag');
      expect(median, lessThan(20000), reason: 'Timer($ms ms): $lag');
    }
  });

  _onMac('a boot that fails is reported as itself', (_) async {
    final c = await _connect();
    addTearDown(() async {
      await c.caller.close();
      await c.bridge.close();
    });
    expect(
      await _say(c.caller, 'BootFailure'),
      contains('configure exploded on purpose'),
    );
  });

  _onMac('a script after the guest runs in its context', (_) async {
    final c = await _connect(
      scripts: const [
        RpcJsScript(
          'plugin.js',
          'globalThis.fromScript = typeof self + ":42";',
        ),
      ],
    );
    addTearDown(() async {
      await c.caller.close();
      await c.bridge.close();
    });
    expect(await _say(c.caller, 'Global', 'fromScript'), 'object:42');
  });

  _onMac('a script that throws fails the load, naming the script', (_) async {
    await expectLater(
      _connect(
        scripts: const [RpcJsScript('broken.js', '\n\nnoSuchFunction();')],
      ),
      throwsA(
        isA<RpcStatusException>().having(
          (e) => e.message,
          'message',
          allOf(contains('broken.js:3'), contains('noSuchFunction')),
        ),
      ),
    );
  });

  _onMac('what one call costs', (_) async {
    final c = await _connect();
    addTearDown(() async {
      await c.caller.close();
      await c.bridge.close();
    });
    await _say(c.caller, 'Say', 'warm-up');
    for (final (label, n, size) in [
      ('empty unary', 200, 0),
      ('1 KiB response', 200, 1024),
      ('64 KiB response', 100, 65536),
      ('1 MiB response', 20, 1048576),
    ]) {
      final micros = <int>[];
      for (var i = 0; i < n; i++) {
        final clock = Stopwatch()..start();
        if (size == 0) {
          await _say(c.caller, 'Say', '');
        } else {
          await _say(c.caller, 'Big', '$size');
        }
        micros.add(clock.elapsedMicroseconds);
      }
      micros.sort();
      String ms(int us) => '${(us / 1000).toStringAsFixed(1)} ms';
      // ignore: avoid_print
      print(
        'FRAME COST $label n=$n p50=${ms(micros[n ~/ 2])} '
        'p99=${ms(micros[(n * 0.99).floor().clamp(0, n - 1)])}',
      );
    }
  });
}
