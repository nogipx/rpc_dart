// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// RpcFlutterWasmBridge registers TWO message handlers in its constructor --
// `incoming` and `console` -- but close() cleared only `incoming` and closed
// only `_incoming`. Per load/close cycle that left:
//
//   * the console handler still registered on the BinaryMessenger. A registered
//     handler is a closure holding the bridge, so the bridge and both its
//     controllers could never be collected.
//   * `_console` never closed, so anything awaiting that stream's completion
//     waited forever -- console.drain() or asFuture() on it never finished.
//
// Nothing caught it because the suite's only bridge is FakeWasmBridge: the real
// Flutter bridge had no test coverage of close() at all. These tests drive the
// real one through a mocked MethodChannel.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rpc_dart_wasm/rpc_dart_wasm.dart';

const _channel = MethodChannel('rpc_dart_wasm');
const _runtimeId = 'rt-1';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late TestDefaultBinaryMessenger messenger;
  final closeRuntimeCalls = <String>[];

  setUp(() {
    closeRuntimeCalls.clear();
    messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_channel, (call) async {
      switch (call.method) {
        case 'loadRuntime':
          return <Object?, Object?>{'runtimeId': _runtimeId};
        case 'closeRuntime':
          closeRuntimeCalls.add((call.arguments as Map)['runtimeId'] as String);
          return null;
        default:
          return null;
      }
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(_channel, null);
  });

  Future<RpcFlutterWasmBridge> load() =>
      RpcFlutterWasmBridge.load(wasmBytes: Uint8List(0), mjsCode: '');

  /// Pushes one line onto the bridge's console channel, as native would.
  Future<void> pushConsole(String text) async {
    final bytes = Uint8List.fromList(text.codeUnits);
    await messenger.handlePlatformMessage(
      'rpc_dart_wasm/$_runtimeId/console',
      ByteData.view(bytes.buffer),
      (_) {},
    );
  }

  group('close()', () {
    // WITNESS: the console stream never completed.
    test('completes the console stream', () async {
      final bridge = await load();
      final consoleDone = bridge.console.drain<void>();

      await bridge.close();

      await expectLater(
        consoleDone.timeout(const Duration(seconds: 2)),
        completes,
        reason:
            'console never closed, so anything awaiting it -- drain(), '
            'asFuture() -- waits forever after the bridge is gone',
      );
    });

    // WITNESS: the console handler stayed registered, holding the bridge.
    //
    // A stale handler is a pure retention bug -- it still guards on `_closed`,
    // so it behaves inertly and cannot be caught by observing the bridge. The
    // one black-box difference is who owns the channel afterwards: with no
    // listener the engine BUFFERS the message and hands it to the next
    // listener that registers; with the bridge's closure still installed the
    // message is consumed there and dropped. So a fresh listener receiving the
    // message is evidence that the closure holding the bridge is gone.
    test('unregisters the console message handler', () async {
      final bridge = await load();
      await bridge.close();

      final channel = 'rpc_dart_wasm/$_runtimeId/console';
      final bytes = Uint8List.fromList('I:after-close'.codeUnits);
      ServicesBinding.instance.channelBuffers.push(
        channel,
        ByteData.view(bytes.buffer),
        (_) {},
      );

      final delivered = Completer<ByteData?>();
      messenger.setMessageHandler(channel, (message) async {
        if (!delivered.isCompleted) delivered.complete(message);
        return null;
      });
      addTearDown(() => messenger.setMessageHandler(channel, null));

      await expectLater(
        delivered.future.timeout(const Duration(seconds: 2)),
        completes,
        reason:
            'the bridge still owns the console channel after close(), so the '
            'closure retaining it -- and both its controllers -- can never be '
            'collected',
      );
    });

    test('still tells native to close the runtime', () async {
      final bridge = await load();
      await bridge.close();

      expect(closeRuntimeCalls, [_runtimeId]);
    });

    test('is idempotent', () async {
      final bridge = await load();
      await bridge.close();
      await bridge.close();

      expect(closeRuntimeCalls, [_runtimeId]);
      expect(bridge.isClosed, isTrue);
    });
  });

  group('before close the bridge still works', () {
    // GUARDS: pass on both sides -- clearing handlers must not break the live
    // path.
    test('console lines are delivered', () async {
      final bridge = await load();
      final seen = <String>[];
      final sub = bridge.console.listen(seen.add);

      await pushConsole('I:hello\nW:careful');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(seen, ['I:hello', 'W:careful']);

      await sub.cancel();
      await bridge.close();
    });

    test('incoming bytes are delivered', () async {
      final bridge = await load();
      final seen = <Uint8List>[];
      final sub = bridge.incoming.listen(seen.add);

      final payload = Uint8List.fromList([1, 2, 3]);
      await messenger.handlePlatformMessage(
        'rpc_dart_wasm/$_runtimeId/incoming',
        ByteData.view(payload.buffer),
        (_) {},
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(seen, hasLength(1));
      expect(seen.single, payload);

      await sub.cancel();
      await bridge.close();
    });
  });
}
