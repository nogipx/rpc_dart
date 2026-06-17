// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Web (dart2js) compile guard for the WEB variant of the Isolate transport.
//
// On web, `package:rpc_dart_isolate/rpc_dart_isolate.dart` resolves to
// `isolate_transport_web.dart`, which uses Web Workers via `package:isolate_manager`
// and imports isolate_manager's private `src/` (implementation_imports). A minor
// isolate_manager bump can silently break that import chain. This test forces the
// whole web branch to compile to JS, so such a breakage fails CI instead of only
// surfacing at runtime in a real browser.
//
// It does NOT spawn a real Web Worker (that needs a separately-built worker
// script). It proves the web build compiles and exposes the public API.
@TestOn('browser')
library;

import 'package:rpc_dart_isolate/rpc_dart_isolate.dart';
import 'package:test/test.dart';

void main() {
  test('web isolate transport compiles to JS and exposes its API', () {
    // Referencing these forces dart2js to resolve the entire web import chain
    // (including isolate_manager's private src/ imports).
    expect(RpcIsolateTransport.spawn, isA<Function>());
    expect(runRpcIsolateManagerWorker, isA<Function>());
  });
}
