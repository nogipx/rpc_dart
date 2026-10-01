// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// `RpcIsolateTransport.spawn` opened `initPort`, `errorPort` and `exitPort` before
// `await Isolate.spawn(...)` with no guard. An open ReceivePort keeps the Dart event
// loop alive, so a spawn that THREW left three of them behind and the process never
// exited -- a CLI or test runner that fails to spawn hangs for ever.
//
// Measured with an unsendable `customParams` value, which makes `Isolate.spawn`
// throw ArgumentError while building its message:
//
//     guard ablated    the process printed its last line and never exited
//     guard in place   exited immediately
//
// THE OBSERVABLE IS PROCESS EXIT, which no in-process test can assert about itself,
// so the witness is a SUBPROCESS -- the same shape round 323 needed. The fixture is
// `test/fixtures/spawn_failure_must_exit.dart` and it deliberately does not call
// `exit()`.
@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';

void main() {
  test(
    'a process whose spawn failed still exits',
    () async {
      // Relative on purpose: `dart test` runs from the package root, and the
      // package has no `package:path` dependency to join with.
      const fixture = 'test/fixtures/spawn_failure_must_exit.dart';
      expect(
        File(fixture).existsSync(),
        isTrue,
        reason:
            'the fixture IS the subject; without it this test proves nothing',
      );

      final process = await Process.start(Platform.resolvedExecutable, [
        'run',
        fixture,
      ]);
      final output = StringBuffer();
      process.stdout
          .transform(const SystemEncoding().decoder)
          .listen(output.write);
      process.stderr
          .transform(const SystemEncoding().decoder)
          .listen(output.write);

      // Generous: the fixture does no work beyond one failed spawn, so a process
      // that is going to exit does so in seconds. Anything past this is the event
      // loop being held open.
      final code = await process.exitCode.timeout(
        const Duration(seconds: 45),
        onTimeout: () {
          process.kill(ProcessSignal.sigkill);
          return -1;
        },
      );

      expect(
        output.toString(),
        contains('threw ArgumentError'),
        reason:
            'the arm needs the spawn to have FAILED; if it stopped throwing, '
            'the ports are never leaked and this test is vacuous',
      );
      expect(
        code,
        isNot(-1),
        reason:
            'three ReceivePorts left open by a failed spawn keep the event '
            'loop alive, so the process never exits',
      );
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );
}
