// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Real end-to-end Web Worker RPC test for the web Isolate transport.
//
// Unlike `web_smoke_test.dart` (a compile guard), this test spawns an ACTUAL
// dedicated Web Worker from a SEPARATELY-COMPILED worker script
// (`echo_worker.dart.js`) and performs real unary + server-stream RPCs over the
// `RpcIsolateTransport` web bridge, asserting the round-trip results.
//
// IMPORTANT: this requires a pre-compile step (a plain `dart test` will NOT
// build the worker). Run:
//
//   fvm dart compile js test/web_worker/echo_worker.dart \
//     -o test/web_worker/echo_worker.dart.js
//   fvm dart test -p chrome test/web_worker/echo_worker_test.dart
//
// URL resolution: `dart test` serves the package root statically behind a
// per-run secret path. The test HTML page lives at
//   <serverUrl>/<secret>/test/web_worker/echo_worker_test.html
// so the compiled worker (a sibling file in the same directory) resolves via
// `Uri.base.resolve('echo_worker.dart.js')`, which carries the same secret
// prefix and directory.
@TestOn('browser')
library;

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_isolate/rpc_dart_isolate.dart';
import 'package:test/test.dart';

// Required so `RpcIsolateTransport.spawn` keeps API parity; on web the actual
// server logic lives in the compiled worker, not in this function.
void _unusedEntrypoint(IRpcTransport transport, Map<String, dynamic> params) {}

void main() {
  test('real Web Worker unary + server-stream RPC round-trip', () async {
    final workerUri = Uri.base.resolve('echo_worker.dart.js');

    final spawned = await RpcIsolateTransport.spawn(
      entrypoint: _unusedEntrypoint,
      workerUri: workerUri,
      customParams: const {'hello': 'worker'},
    );

    final caller = RpcCallerEndpoint(transport: spawned.transport);

    try {
      // Unary round-trip.
      final response = await caller
          .unaryRequest<RpcString, RpcString>(
            serviceName: 'EchoService',
            methodName: 'Echo',
            requestCodec: RpcString.codec,
            responseCodec: RpcString.codec,
            request: 'ping'.rpc,
          )
          .timeout(const Duration(seconds: 10));

      expect(response.value, 'echo:ping');

      // Server-stream round-trip.
      final received = <String>[];
      await for (final item in caller
          .serverStream<RpcString, RpcString>(
            serviceName: 'EchoService',
            methodName: 'EchoStream',
            requestCodec: RpcString.codec,
            responseCodec: RpcString.codec,
            request: 'x'.rpc,
          )
          .timeout(const Duration(seconds: 10))) {
        received.add(item.value);
      }

      expect(received, ['stream:x:0', 'stream:x:1', 'stream:x:2']);
    } finally {
      await caller.close();
      spawned.kill();
    }
  });
}
