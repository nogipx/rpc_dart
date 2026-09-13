// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// `stripModuleSyntax` removes FOUR literal prefixes:
//
//   "export async function " "export const " "export function " "export class "
//
// The glue the current SDK emits uses exactly those, which is why it works. It
// is pinned to nothing: `export let`, `export default`, a trailing
// `export {compile, instantiate}` or any `import` all survive the strip and
// reach the engine as module syntax inside a classic script.
//
// Measured on an Android 11 emulator, what a caller was told:
//
//   mutation              before                          after
//   unmutated (control)   booted                          booted
//   export let            SyntaxError: Unexpected token   the plugin names the
//   export default        'export' ...                    construct and says
//   trailing export {}                                    stripModuleSyntax
//   a leading import      Cannot use import statement...  needs updating
//
// On Android the old message already named the token, so this is a diagnostic
// improvement there. On iOS it is not: a SyntaxError kills the whole <script>
// tag, so the IIFE never defines `compile` and the failure surfaces as the 30 s
// boot watchdog blaming something else. That half is unmeasured -- see B-42.
//
// The GUARD is the one that matters. The words "export" and "import" appear 19
// times in the real glue and only 4 at statement position
// (`dartInstance.exports`, `importObjectPromise`, a comment naming the 'import'
// API), so a `contains` check would refuse every working boot -- far worse than
// the failure it diagnoses. The control pins that.
@TestOn('vm')
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:rpc_dart_wasm/rpc_dart_wasm.dart';

/// Loads with [mjs] and reports what the caller was told.
Future<String> _load(Uint8List wasm, String mjs) async {
  try {
    final bridge = await RpcFlutterWasmBridge.load(
      wasmBytes: wasm,
      mjsCode: mjs,
    ).timeout(const Duration(seconds: 90));
    await bridge.close();
    return 'booted';
  } catch (e) {
    return e.toString().replaceAll('\n', ' ');
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Uint8List wasm;
  late String mjs;

  setUpAll(() async {
    wasm = (await rootBundle.load('assets/guest.wasm')).buffer.asUint8List();
    mjs = await rootBundle.loadString('assets/guest.mjs');
  });

  // GUARD, and the load-bearing one: the REAL glue must still boot. A check
  // that refused it would be a far worse defect than the one being fixed, and
  // every witness below would still pass.
  testWidgets(
    'GUARD: the real dart2wasm glue still boots',
    (_) async {
      expect(await _load(wasm, mjs), 'booted');
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );

  // WITNESS: each form the strip does not handle must name itself.
  for (final (label, mutate) in <(String, String Function(String))>[
    ('export let', (s) => s.replaceFirst('export const ', 'export let ')),
    ('export default', (s) => '$s\nexport default compile;\n'),
    ('trailing export {}', (s) => '$s\nexport {compile, instantiate};\n'),
    ('a leading import', (s) => "import * as x from './y.mjs';\n$s"),
  ]) {
    testWidgets(
      'an unstripped "$label" is reported as itself',
      (_) async {
        final outcome = await _load(wasm, mutate(mjs));

        expect(
          outcome,
          contains('module syntax this plugin does not strip'),
          reason:
              'the caller saw a raw JS SyntaxError and had to work out that '
              'the plugin failed to strip its glue',
        );
        expect(
          outcome,
          contains('stripModuleSyntax'),
          reason: 'the message must name what to change',
        );
      },
      timeout: const Timeout(Duration(minutes: 5)),
    );
  }
}
