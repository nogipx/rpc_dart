// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Bytes that cross the bridge while either side is still booting.
//
// Host side: native pushes what the guest sends during `invokeMain`, and that
// runs BEFORE `loadRuntime` returns -- so before the Dart bridge has installed
// its message handler. Flutter's channel buffers hold what arrives meanwhile.
//
// Guest side: a frame the host sends before the guest has installed
// `rpcWasmReceiveBytes` reaches a guest with nowhere to put it.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:rpc_dart_wasm/rpc_dart_wasm.dart';

String _guest({required String invokeMainBody, String prelude = ''}) =>
    '''
$prelude
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

Future<RpcFlutterWasmBridge> _boot(String mjs) => RpcFlutterWasmBridge.load(
  wasmBytes: Uint8List.fromList([0, 1, 2, 3]),
  mjsCode: mjs,
).timeout(const Duration(seconds: 45));

Future<List<int>> _collect(Stream<Uint8List> s, Duration window) async {
  final got = <int>[];
  final sub = s.listen(got.addAll);
  await Future<void>.delayed(window);
  await sub.cancel();
  return got;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('frames the guest sends during boot all reach Dart', (_) async {
    final bridge = await _boot(
      _guest(
        invokeMainBody:
            '_rpcWasmSendBytes(new Uint8Array([1])); '
            '_rpcWasmSendBytes(new Uint8Array([2])); '
            '_rpcWasmSendBytes(new Uint8Array([3]));',
      ),
    );
    addTearDown(bridge.close);

    final got = await _collect(bridge.incoming, const Duration(seconds: 3));
    // ignore: avoid_print
    print('boot frames received: $got');
    expect(got, [1, 2, 3]);
  });

  testWidgets('a frame sent before the guest installs its receiver arrives', (
    _,
  ) async {
    // The guest echoes, but installs the receiver 500 ms into its main.
    final bridge = await _boot(
      _guest(
        invokeMainBody:
            'setTimeout(function() { globalThis.rpcWasmReceiveBytes = '
            'function(b) { _rpcWasmSendBytes(b); }; }, 500);',
      ),
    );
    addTearDown(bridge.close);

    final got = _collect(bridge.incoming, const Duration(seconds: 3));
    await bridge.send(Uint8List.fromList([7, 8, 9]));
    final echoed = await got;
    // ignore: avoid_print
    print('early host frame echoed: $echoed');
    expect(echoed, [7, 8, 9]);
  });
}
