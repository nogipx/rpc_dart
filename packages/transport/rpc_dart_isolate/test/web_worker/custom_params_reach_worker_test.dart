// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// `RpcIsolateTransport.spawn(customParams: ...)` delivers those params to the
// worker entrypoint. On web the worker picks them up with
//
//     controller.onIsolateMessage.first.then((raw) { ... init ... })
//
// which takes the FIRST message the host sends -- and that is not the init
// message. `RpcChannelTransport` advertises the connection flow-control window
// from its own CONSTRUCTOR, synchronously, and spawn() builds the transport
// before it sends init. So `.first` receives a metadata frame, the `init` branch
// does not match, and the fallback hands the entrypoint `const {}`.
//
// The real init message then arrives at the channel, whose handler treats
// _BridgeType.init as a no-op. Nothing errors; the params are simply gone.
//
// The existing e2e test already passed `customParams: {'hello': 'worker'}` and
// never asserted they arrived, which is why this survived — the same shape as
// the wasm test double that shared the production bug.
//
// Build (a plain `dart test` will NOT rebuild the worker):
//   fvm dart compile js test/web_worker/echo_worker.dart \
//     -o test/web_worker/echo_worker.dart.js
@TestOn('browser')
library;

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_isolate/rpc_dart_isolate.dart';
import 'package:test/test.dart';

void _unusedEntrypoint(IRpcTransport transport, Map<String, dynamic> params) {}

Future<String> _paramsSeenByWorker(Map<String, dynamic> customParams) async {
  final spawned = await RpcIsolateTransport.spawn(
    entrypoint: _unusedEntrypoint,
    workerUri: Uri.base.resolve('echo_worker.dart.js'),
    customParams: customParams,
  );
  final caller = RpcCallerEndpoint(transport: spawned.transport);
  try {
    final reported = await caller
        .unaryRequest<RpcString, RpcString>(
          serviceName: 'EchoService',
          methodName: 'Params',
          requestCodec: RpcString.codec,
          responseCodec: RpcString.codec,
          request: ''.rpc,
        )
        .timeout(const Duration(seconds: 15));
    return reported.value;
  } finally {
    await caller.close();
    spawned.kill();
  }
}

void main() {
  test(
    'WITNESS: customParams reach the worker entrypoint',
    () async {
      expect(
        await _paramsSeenByWorker(const {'hello': 'worker', 'n': '7'}),
        'hello=worker,n=7',
        reason:
            'the worker was handed an empty map: `.first` consumed the '
            'flow-control advertisement instead of the init message',
      );
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test(
    'GUARD: an empty customParams map still starts the worker',
    () async {
      // Load-bearing: the fix must not make the absence of params a failure, and
      // a worker that never starts would fail the witness for the wrong reason.
      expect(await _paramsSeenByWorker(const {}), '');
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test(
    'GUARD: ordinary RPC still works',
    () async {
      // The init handling sits on the path every call depends on.
      final spawned = await RpcIsolateTransport.spawn(
        entrypoint: _unusedEntrypoint,
        workerUri: Uri.base.resolve('echo_worker.dart.js'),
        customParams: const {'k': 'v'},
      );
      final caller = RpcCallerEndpoint(transport: spawned.transport);
      try {
        final response = await caller
            .unaryRequest<RpcString, RpcString>(
              serviceName: 'EchoService',
              methodName: 'Echo',
              requestCodec: RpcString.codec,
              responseCodec: RpcString.codec,
              request: 'ping'.rpc,
            )
            .timeout(const Duration(seconds: 15));
        expect(response.value, 'echo:ping');
      } finally {
        await caller.close();
        spawned.kill();
      }
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );
}
