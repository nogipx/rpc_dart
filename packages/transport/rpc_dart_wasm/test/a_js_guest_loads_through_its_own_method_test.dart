// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A guest compiled to JavaScript loads through `loadJsRuntime`, with its code,
// the scripts to run after it and the runtime id the bridge chose -- and a
// plugin that runs no JS guest answers UNAVAILABLE, not a MissingPluginException
// the caller has to know about.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rpc_dart/rpc_dart.dart' show RpcStatus, RpcStatusException;
import 'package:rpc_dart_wasm/rpc_dart_wasm.dart';

const _channel = MethodChannel('rpc_dart_wasm');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late TestDefaultBinaryMessenger messenger;
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  });

  tearDown(() => messenger.setMockMethodCallHandler(_channel, null));

  test(
    'the code, the scripts after it and the chosen id go to native',
    () async {
      messenger.setMockMethodCallHandler(_channel, (call) async {
        calls.add(call);
        if (call.method == 'loadJsRuntime') {
          return <Object?, Object?>{
            'runtimeId': (call.arguments as Map)['runtimeId'],
          };
        }
        return null;
      });
      final bridge = await RpcFlutterWasmBridge.loadJs(
        code: 'guest()',
        scripts: const [RpcJsScript('main.js', 'plugin()')],
        jsBootPrefix: 'prefix()',
      );
      addTearDown(bridge.close);
      final args = (calls.single.arguments as Map).cast<String, Object?>();
      expect(calls.single.method, 'loadJsRuntime');
      expect(args['code'], 'guest()');
      expect(args['jsBootPrefix'], 'prefix()');
      expect(args['scripts'], [
        {'name': 'main.js', 'code': 'plugin()'},
      ]);
      expect(args['runtimeId'], bridge.runtimeId);
    },
  );

  test(
    'a script that throws at boot fails the load with its message',
    () async {
      messenger.setMockMethodCallHandler(_channel, (call) async {
        return <Object?, Object?>{
          'runtimeId': null,
          'error': 'main.js:3: ReferenceError: nope',
        };
      });
      await expectLater(
        RpcFlutterWasmBridge.loadJs(code: ''),
        throwsA(
          isA<RpcStatusException>().having(
            (e) => e.message,
            'message',
            contains('main.js:3: ReferenceError: nope'),
          ),
        ),
      );
    },
  );

  test('a plugin that runs no JS guest: UNAVAILABLE', () async {
    messenger.setMockMethodCallHandler(_channel, (call) async {
      throw MissingPluginException();
    });
    await expectLater(
      RpcFlutterWasmBridge.loadJs(code: ''),
      throwsA(
        isA<RpcStatusException>().having(
          (e) => e.statusCode,
          'statusCode',
          RpcStatus.unavailable,
        ),
      ),
    );
  });

  test('only a plugin that says so runs a JS guest', () {
    RpcWasmSupportInfo info(Map<String, Object?> details) => RpcWasmSupportInfo(
      jsEngineAvailable: true,
      webAssemblyAvailable: false,
      wasmGcSupported: false,
      details: details,
    );
    expect(info(const {'jsGuest': true}).canRunJsGuest, isTrue);
    expect(info(const {}).canRunJsGuest, isFalse);
    expect(info(const {'jsGuest': true}).canRunDartWasm, isFalse);
  });
}
