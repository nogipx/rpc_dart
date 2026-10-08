// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// When the native plugin answers loadRuntime with a runtime id other than the
// one requested, load() releases that foreign runtime without waiting on it
// and fails with UNAVAILABLE. The release must not leak an error of its own:
// nobody awaits it, so a closeRuntime that fails would surface as an uncaught
// async error next to the UNAVAILABLE the caller already gets.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rpc_dart/rpc_dart.dart' show RpcStatus, RpcStatusException;
import 'package:rpc_dart_wasm/rpc_dart_wasm.dart';

const _channel = MethodChannel('rpc_dart_wasm');
const _foreignId = 'not-the-one-requested';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late TestDefaultBinaryMessenger messenger;
  final closeRuntimeCalls = <String>[];

  void mockPlugin({required bool closeFails}) {
    messenger.setMockMethodCallHandler(_channel, (call) async {
      switch (call.method) {
        case 'loadRuntime':
          return <Object?, Object?>{'runtimeId': _foreignId};
        case 'closeRuntime':
          closeRuntimeCalls.add((call.arguments as Map)['runtimeId'] as String);
          if (closeFails) {
            throw PlatformException(code: 'gone', message: 'no such runtime');
          }
          return null;
        default:
          return null;
      }
    });
  }

  setUp(() {
    closeRuntimeCalls.clear();
    messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  });

  tearDown(() => messenger.setMockMethodCallHandler(_channel, null));

  Future<void> loadExpectingUnavailable() async {
    await expectLater(
      RpcFlutterWasmBridge.load(wasmBytes: Uint8List(0), mjsCode: ''),
      throwsA(
        isA<RpcStatusException>().having(
          (e) => e.statusCode,
          'statusCode',
          RpcStatus.unavailable,
        ),
      ),
    );
    // The release is not awaited by load(); give it the turns it needs.
    await pumpEventQueue();
  }

  test('the foreign runtime is released', () async {
    mockPlugin(closeFails: false);
    await loadExpectingUnavailable();
    expect(closeRuntimeCalls, [_foreignId]);
  });

  test(
    'WITNESS a failing release does not escape as an uncaught error',
    () async {
      mockPlugin(closeFails: true);
      await loadExpectingUnavailable();
      expect(closeRuntimeCalls, [_foreignId]);
    },
  );
}
