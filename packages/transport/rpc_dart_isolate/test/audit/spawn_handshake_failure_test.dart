// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_isolate/rpc_dart_isolate.dart';
import 'package:test/test.dart';

/// Entrypoint that throws immediately, before the RPC handshake completes.
@pragma('vm:entry-point')
void throwingEntrypoint(IRpcTransport transport, Map<String, dynamic> params) {
  throw StateError('boom: worker failed during startup');
}

/// Entrypoint that hangs forever without ever using the transport.
/// (The handshake itself completes; this is only used to exercise the
/// post-handshake path, not the timeout. Kept minimal.)
@pragma('vm:entry-point')
void idleEntrypoint(IRpcTransport transport, Map<String, dynamic> params) {
  // Intentionally does nothing.
}

void main() {
  group('RpcIsolateTransport.spawn handshake failure', () {
    test(
      'isolate throwing before handshake surfaces the error instead of hanging',
      () async {
        Object? caught;
        try {
          await RpcIsolateTransport.spawn(
            entrypoint: throwingEntrypoint,
            isolateId: 'audit-throwing',
            startupTimeout: const Duration(seconds: 5),
          );
        } catch (e) {
          caught = e;
        }

        expect(
          caught,
          isNotNull,
          reason:
              'spawn() must throw, not hang, when the isolate crashes '
              'before the handshake',
        );
        // The original isolate error message must be surfaced.
        expect(caught.toString(), contains('boom: worker failed'));
      },
      timeout: const Timeout(Duration(seconds: 15)),
    );

    test(
      'successful spawn still works (regression guard)',
      () async {
        final spawned = await RpcIsolateTransport.spawn(
          entrypoint: idleEntrypoint,
          isolateId: 'audit-idle',
          startupTimeout: const Duration(seconds: 5),
        );
        expect(spawned.transport, isNotNull);
        spawned.kill();
      },
      timeout: const Timeout(Duration(seconds: 15)),
    );
  });
}
