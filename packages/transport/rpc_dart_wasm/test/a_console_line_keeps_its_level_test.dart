// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Each console entry is prefixed with its level once, and an entry may span
// lines: a stack trace, or the guest zone's `error\nstack`. Android also joins
// several entries into one message with `\n`. The bridge splits on `\n`, so
// every line after the first must carry the level of the entry it belongs to,
// or a consumer filtering on `E:` sees the message and none of its stack.

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rpc_dart_wasm/rpc_dart_wasm.dart';

const _channel = MethodChannel('rpc_dart_wasm');
const _runtimeId = 'rt-1';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late TestDefaultBinaryMessenger messenger;

  setUp(() {
    messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_channel, (call) async {
      if (call.method == 'loadRuntime') {
        return <Object?, Object?>{'runtimeId': _runtimeId};
      }
      return null;
    });
  });

  tearDown(() => messenger.setMockMethodCallHandler(_channel, null));

  Future<List<String>> linesFor(String text) async {
    final bridge = await RpcFlutterWasmBridge.load(
      wasmBytes: Uint8List(0),
      mjsCode: '',
    );
    addTearDown(bridge.close);
    final lines = <String>[];
    final sub = bridge.console.listen(lines.add);
    addTearDown(sub.cancel);
    final bytes = Uint8List.fromList(utf8.encode(text));
    await messenger.handlePlatformMessage(
      'rpc_dart_wasm/$_runtimeId/console',
      ByteData.view(bytes.buffer),
      (_) {},
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    return lines;
  }

  test('WITNESS every line of a multi-line entry carries its level', () async {
    expect(await linesFor('E:Unhandled error: boom\n#0 main\n#1 run'), [
      'E:Unhandled error: boom',
      'E:#0 main',
      'E:#1 run',
    ]);
  });

  test('WITNESS entries joined in one message keep their own levels', () async {
    expect(await linesFor('E:boom\n#0 main\nI:next\nW:careful'), [
      'E:boom',
      'E:#0 main',
      'I:next',
      'W:careful',
    ]);
  });

  test('GUARD single-line entries are unchanged', () async {
    expect(await linesFor('I:hello\nD:detail'), ['I:hello', 'D:detail']);
  });
}
