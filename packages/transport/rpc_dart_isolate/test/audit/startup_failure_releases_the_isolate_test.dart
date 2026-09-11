// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A spawn that TIMES OUT must leave nothing behind.
//
// `spawn()` acquires an isolate, three ReceivePorts and three subscriptions
// before it waits for the worker's ready ack. When that wait expires it throws,
// and the caller is holding nothing it could release -- so if the failure path
// does not tear down, a stuck isolate and its ports leak on a call that already
// looked like it failed cleanly.
//
// Round 223 measured the path clean, and round 246 re-swept it, but RPC-14's own
// record said what neither established: with `teardownStartup()` deleted the
// isolate suite still passed `+73`. This is that missing witness. The ablations
// it was built against, both on the ready-timeout path in `isolate_transport`:
//
//   teardownStartup() removed     still running  (killed at 20s)
//   hostTransport.close() removed still running  (killed at 20s)
//   neither removed               exited 0
//
// The observable has to be the child's own exit. An open ReceivePort keeps the
// event loop alive, and nothing inside the same isolate can see that directly --
// which is also why there is no watchdog Timer anywhere here, since a pending
// Timer would keep the loop alive by itself and report a hang unconditionally.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';

/// Runs a support script and reports how it finished.
Future<String> _outcome(String script) async {
  final path = Directory.current.path.endsWith('rpc_dart_isolate')
      ? 'test/support/$script'
      : 'packages/transport/rpc_dart_isolate/test/support/$script';
  final proc = await Process.start(Platform.resolvedExecutable, ['run', path]);
  unawaited(proc.stdout.drain<void>());
  unawaited(proc.stderr.drain<void>());
  final code = await proc.exitCode
      .timeout(const Duration(seconds: 20))
      .catchError((Object _) => -999);
  if (code == -999) {
    proc.kill(ProcessSignal.sigkill);
    return 'still running';
  }
  return 'exited $code';
}

void main() {
  test(
    'a spawn that times out leaves no isolate and no ports behind',
    () async {
      expect(
        await _outcome('exits_after_failed_startup.dart'),
        'exited 0',
        reason:
            'the failed startup left the isolate alive or a port open, so the '
            'host event loop never drained and the process could not end',
      );
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );
}
