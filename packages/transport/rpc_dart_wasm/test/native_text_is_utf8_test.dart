// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Both plugins encode text as UTF-8 and nothing else:
//
//   ios/Classes/RpcDartWasmPlugin.swift:581,629  reason/log.data(using: .utf8)
//   android/.../RpcDartWasmPlugin.kt:425,493     reason/log.toByteArray(UTF_8)
//
// The bridge decoded both channels with String.fromCharCodes, a byte-per-
// character reinterpretation rather than a decoder. For ASCII the two agree
// byte for byte, which is why every existing test passed -- and why the helper
// they all share builds its payload with `text.codeUnits`.
//
// Measured, characters sent against characters arrived:
//
//   ascii (control)  22 ch / 22 B   ->  22 ch   I:hello from the guest
//   cyrillic         17 ch / 30 B   ->  30 ch   I:Ð¿ÑÐ¸Ð²ÐµÑ ...
//   emoji             9 ch / 11 B   ->  11 ch   I:done ð
//   accents          19 ch / 22 B   ->  22 ch   I:fÃ¼r spÃ¤ter, naÃ¯ve
//
// The arrived count equals the BYTE count in every broken arm: the signature of
// one character per byte.

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rpc_dart/rpc_dart.dart' show RpcStatusException;
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

  Future<RpcFlutterWasmBridge> load() =>
      RpcFlutterWasmBridge.load(wasmBytes: Uint8List(0), mjsCode: '');

  /// Sends [text] exactly as the plugins do: UTF-8, no other encoding.
  Future<void> pushAsNativeDoes(String channel, String text) async {
    final bytes = Uint8List.fromList(utf8.encode(text));
    await messenger.handlePlatformMessage(
      'rpc_dart_wasm/$_runtimeId/$channel',
      ByteData.view(bytes.buffer),
      (_) {},
    );
  }

  // WITNESS: non-ASCII console output arrived one mojibake character per byte.
  test('a console line survives non-ASCII text', () async {
    final bridge = await load();
    addTearDown(bridge.close);
    final lines = <String>[];
    final sub = bridge.console.listen(lines.add);
    addTearDown(sub.cancel);

    const sent = 'I:привет из гостя, für später, done \u{1F600}';
    await pushAsNativeDoes('console', sent);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(lines, [sent]);
    expect(
      lines.single.length,
      sent.length,
      reason:
          'a byte-per-character read arrives at the BYTE count, '
          '${utf8.encode(sent).length}, not the character count',
    );
  });

  // WITNESS: the death reason takes the same path, and it is what a developer
  // reads when the guest is gone.
  test('the death reason survives non-ASCII text', () async {
    final bridge = await load();
    addTearDown(bridge.close);
    Object? death;
    bridge.incoming.listen((_) {}, onError: (Object e) => death = e);

    await pushAsNativeDoes('died', 'гость упал: нет памяти');
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(death, isA<RpcStatusException>());
    expect(death.toString(), contains('гость упал: нет памяти'));
  });

  // GUARD: ASCII is unchanged. This is what every other test in the suite
  // sends, so a decoder that broke it would be caught here rather than by a
  // puzzling failure elsewhere.
  test('GUARD: ASCII is unchanged', () async {
    final bridge = await load();
    addTearDown(bridge.close);
    final lines = <String>[];
    final sub = bridge.console.listen(lines.add);
    addTearDown(sub.cancel);

    await pushAsNativeDoes('console', 'I:hello from the guest\nW:careful');
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(lines, ['I:hello from the guest', 'W:careful']);
  });

  // GUARD: a truncated multi-byte sequence must not throw. Both call sites are
  // diagnostics -- the console handler runs inside a platform message handler
  // and _reasonOf inside the death report -- so a strict decoder would turn a
  // cut-off log line into a crash, or lose the death notice entirely.
  test('GUARD: malformed bytes are substituted, not thrown', () async {
    final bridge = await load();
    addTearDown(bridge.close);
    final lines = <String>[];
    final sub = bridge.console.listen(lines.add);
    addTearDown(sub.cancel);

    // 'I:' then the first two bytes of a three-byte sequence, cut short.
    final truncated = Uint8List.fromList([0x49, 0x3A, 0xD0, 0xBF, 0xE3, 0x81]);
    await messenger.handlePlatformMessage(
      'rpc_dart_wasm/$_runtimeId/console',
      ByteData.view(truncated.buffer),
      (_) {},
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(lines, hasLength(1));
    expect(lines.single, startsWith('I:п'));
    expect(lines.single, contains('\u{FFFD}'));
  });
}
