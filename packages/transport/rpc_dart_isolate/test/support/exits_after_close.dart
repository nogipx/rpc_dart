// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Support script for close_releases_the_isolate_test.dart.
//
// Spawns a worker, tears the connection down with the mode given in argv[0]
// ("close" or "kill"), and returns from main. Whether this process EXITS is the
// measurement, so there is deliberately no exit() call and no watchdog Timer --
// a pending Timer keeps the event loop alive by itself and would make every run
// look like a hang.

import 'dart:async';
import 'dart:isolate';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_isolate/rpc_dart_isolate.dart';

@pragma('vm:entry-point')
void ackWorker(IRpcTransport transport, Map<String, dynamic> params) {
  (params['ack'] as SendPort).send('up');
}

Future<void> main(List<String> argv) async {
  final mode = argv.isEmpty ? 'close' : argv.first;

  final ack = ReceivePort();
  final up = Completer<void>();
  final ackSub = ack.listen((_) {
    if (!up.isCompleted) up.complete();
  });

  final spawned = await RpcIsolateTransport.spawn(
    entrypoint: ackWorker,
    customParams: {'ack': ack.sendPort},
  );
  await up.future;

  // Release everything this script owns, so the only ports still open are the
  // ones spawn() holds.
  await ackSub.cancel();
  ack.close();

  if (mode == 'kill') {
    spawned.kill();
  } else {
    await spawned.transport.close();
  }
}
