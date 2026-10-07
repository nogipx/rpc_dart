// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// `canRunDartWasm` says no wherever `load()` would refuse. The Android plugin's
// loadRuntime refuses a sandbox without WASM compilation or without
// provide/consume array buffers, and reports both in `checkSupport`; iOS
// reports neither, and needs neither.

import 'package:flutter_test/flutter_test.dart';
import 'package:rpc_dart_wasm/rpc_dart_wasm.dart';

RpcWasmSupportInfo _info(Map<String, Object?> details) => RpcWasmSupportInfo(
  jsEngineAvailable: true,
  webAssemblyAvailable: true,
  wasmGcSupported: true,
  details: details,
);

void main() {
  test('no WASM compilation in the sandbox: cannot run', () {
    expect(
      _info({
        'wasmCompilationSupported': false,
        'namedDataSupported': true,
      }).canRunDartWasm,
      isFalse,
    );
  });

  test('no named data in the sandbox: cannot run', () {
    expect(
      _info({
        'wasmCompilationSupported': true,
        'namedDataSupported': false,
      }).canRunDartWasm,
      isFalse,
    );
  });

  test('GUARD: both supported (Android) can run', () {
    expect(
      _info({
        'wasmCompilationSupported': true,
        'namedDataSupported': true,
      }).canRunDartWasm,
      isTrue,
    );
  });

  test('GUARD: neither reported (iOS) can run', () {
    expect(_info(const {}).canRunDartWasm, isTrue);
  });
}
