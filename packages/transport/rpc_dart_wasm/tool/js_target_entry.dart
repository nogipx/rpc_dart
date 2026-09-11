// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Compiled, never run. It exists so that `lib/src/wasm/rpc_wasm.dart` — this
// package's `dart:js_interop` implementation — is checked against the JS
// target's rules by some gate.
//
// It had none. `test:wasm` is `flutter test`, which runs on the VM;
// `test:wasm:device` builds for iOS and Android; `test:web` does not include
// this package. And `dart analyze` is BLIND to the class: measured in round 345,
// it reports "No issues found!" on the exact tear-off that made
// `dart compile js` fail in round 344 —
//
//   Error: Tear-offs of external extension type interop member 'close' are
//   disallowed.
//
// — so a JS-target compile is the only thing that sees it, and analysing harder
// would not have helped.
//
// Referenced from the `test:wasm` script. If this file stops being compiled the
// coverage goes back to zero silently, which is how it got here.

import 'package:rpc_dart_wasm/src/wasm/rpc_wasm.dart' as web;

void main() {
  // A reference the compiler cannot drop before it has checked the library.
  // ignore: avoid_print
  print(web.RpcWasm);
}
