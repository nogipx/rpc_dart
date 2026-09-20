// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// `IRpcServer.stop()` could not express a drain, so `RpcApp` compensated -- and
// got the order wrong twice.
//
// Two of the three first-party servers already implemented
// `stop({Duration? drainTimeout})`; the interface declared `stop()`. `RpcApp`
// holds an `IRpcServer`, so the widened signature was unreachable and it called
// the hard stop, draining the endpoints itself first:
//
//   1. ep.drain(timeout:) on every endpoint   <- nothing has stopped the
//                                                LISTENER, so a connection
//                                                arriving now gets an
//                                                already-draining endpoint
//   2. module.onStop()
//   3. server.stop()                          <- the listener, finally
//
// And `RpcEndpointBase.drain` is the heavier operation: it CANCELS active
// contexts, which is the opposite of letting in-flight work finish. The
// websocket server documents exactly that as the reason it calls
// `markDraining()` instead -- and `RpcApp` called the one the comment warns
// against.
//
// Now the server drains, and it goes FIRST so a handler can still reach module
// resources while it finishes.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_framework/rpc_dart_framework.dart';
import 'package:test/test.dart';

/// Records what it was asked to do, and when relative to the modules.
final class _RecordingServer implements IRpcServer {
  _RecordingServer(this.log);

  final List<String> log;
  bool _running = false;
  Duration? drainTimeoutSeen;
  var stopCalls = 0;

  @override
  bool get isRunning => _running;

  @override
  List<RpcResponderEndpoint> get endpoints => const [];

  @override
  Future<void> start() async {
    _running = true;
    log.add('server.start');
  }

  @override
  Future<void> stop({Duration? drainTimeout}) async {
    stopCalls++;
    drainTimeoutSeen = drainTimeout;
    _running = false;
    log.add('server.stop');
  }
}

final class _RecordingModule extends RpcModule {
  _RecordingModule(this.log);

  final List<String> log;

  @override
  String get name => 'Recording';

  @override
  Future<void> onStop() async => log.add('module.onStop');
}

void main() {
  test(
    'the app asks the SERVER to drain, with its configured budget',
    () async {
      final log = <String>[];
      final server = _RecordingServer(log);

      final app = RpcApp.server(
        config: const RpcAppConfig(drainTimeout: Duration(seconds: 7)),
        server: (_) => server,
        modules: [_RecordingModule(log)],
      );

      await app.start();
      await app.stop();

      expect(
        server.drainTimeoutSeen,
        const Duration(seconds: 7),
        reason:
            'the app drained the endpoints itself and called the bare stop(), '
            'because the interface could not carry the budget',
      );
    },
  );

  // The order is the load-bearing half: a handler finishing during the drain
  // must still be able to reach what its module owns.
  test(
    'the server stops admitting BEFORE the modules release resources',
    () async {
      final log = <String>[];
      final server = _RecordingServer(log);

      final app = RpcApp.server(
        server: (_) => server,
        modules: [_RecordingModule(log)],
      );

      await app.start();
      await app.stop();

      expect(
        log.indexOf('server.stop'),
        lessThan(log.indexOf('module.onStop')),
        reason: 'handlers finishing in the drain window still need the module',
      );
    },
  );

  // GUARD: stop() is reachable twice and must not stop the server twice.
  test('GUARD: a second stop() is a no-op', () async {
    final log = <String>[];
    final server = _RecordingServer(log);

    final app = RpcApp.server(server: (_) => server, modules: []);

    await app.start();
    await app.stop();
    await app.stop();

    expect(server.stopCalls, 1);
  });
}
