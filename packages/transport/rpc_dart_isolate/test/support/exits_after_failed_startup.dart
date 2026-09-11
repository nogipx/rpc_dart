// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Support script for startup_failure_releases_the_isolate_test.dart.
//
// Spawns a worker that never becomes ready, lets `startupTimeout` fire, and
// returns from main. Whether this process EXITS is the measurement, so there is
// deliberately no exit() call and no watchdog Timer -- a pending Timer keeps the
// event loop alive by itself and would make every run look like a hang.
//
// The worker blocks SYNCHRONOUSLY, which is what makes this the honest case: the
// bootstrap sends its handshake SendPort before it calls the entrypoint, so the
// deadline that fires is the READY one, and a cooperative worker would prove
// nothing about an isolate that cannot be asked to stop.

import 'dart:isolate';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_isolate/rpc_dart_isolate.dart';

@pragma('vm:entry-point')
void blockingWorker(IRpcTransport transport, Map<String, dynamic> params) {
  (params['reached'] as SendPort).send('entered');
  // Never yields, so `ready` is never sent and only a kill reclaims this.
  while (true) {}
}

Future<void> main(List<String> argv) async {
  final reached = ReceivePort();
  final reachedSub = reached.listen((_) {});

  try {
    await RpcIsolateTransport.spawn(
      entrypoint: blockingWorker,
      customParams: {'reached': reached.sendPort},
      startupTimeout: const Duration(milliseconds: 500),
    );
    print('UNEXPECTED: spawn returned');
  } catch (e) {
    // The message says WHICH deadline fired, and the two have different
    // teardowns: the handshake one runs teardownStartup() alone, the ready one
    // closes the host transport first.
    print('spawn threw $e');
  }

  // Release everything this script owns, so the only ports that could still be
  // open are the ones spawn() acquired.
  await reachedSub.cancel();
  reached.close();
}
