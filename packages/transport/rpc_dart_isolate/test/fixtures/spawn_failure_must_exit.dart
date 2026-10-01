// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Run as a SUBPROCESS by `a_failed_spawn_lets_the_process_exit_test.dart`.
//
// `Isolate.spawn` is made to throw -- a ReceivePort cannot cross an isolate boundary
// -- after `RpcIsolateTransport.spawn` has opened its three ports. If those are left
// open the event loop never drains and this process never exits, so the test's
// observable is this program's exit code.
//
// Deliberately NO `exit()`: calling it would end the process whatever the ports are
// doing, which is the one thing that must not be faked here.

import 'dart:io';
import 'dart:isolate';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_isolate/rpc_dart_isolate.dart';

void _entry(IRpcTransport transport, Map<String, dynamic> customParams) {}

Future<void> main() async {
  // This port is the unsendable value AND a hazard: left open it would hold the
  // process by itself, so the arm would pass for the wrong reason.
  final unsendable = ReceivePort();
  try {
    await RpcIsolateTransport.spawn(
      entrypoint: _entry,
      customParams: {'unsendable': unsendable},
      isolateId: 'fixture',
    );
    stdout.writeln('NO THROW');
  } catch (e) {
    stdout.writeln('threw ${e.runtimeType}');
  }
  unsendable.close();
}
