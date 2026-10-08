// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// stop() called while start() was still running its modules' onStart found no
// server yet, marked the app stopped, and returned. start() then went on to
// start the server, and every later stop() returned at once: a listener
// nothing could stop. stop() now waits for the start in progress.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_framework/rpc_dart_framework.dart';
import 'package:test/test.dart';

class _SlowModule extends RpcServerModule {
  var started = false;
  var stopped = false;

  @override
  String get name => 'Slow';

  @override
  Future<void> onStart(RpcContainer container) async {
    await Future<void>.delayed(const Duration(milliseconds: 200));
    started = true;
  }

  @override
  Future<void> onStop() async => stopped = true;

  @override
  List<RpcResponderContract> buildContracts(RpcContainer container) => const [];
}

class _Server implements IRpcServer {
  _Server(this._onEndpoint);
  final void Function(RpcResponderEndpoint) _onEndpoint;
  var running = false;

  @override
  bool get isRunning => running;

  @override
  List<RpcResponderEndpoint> get endpoints => const [];

  @override
  Future<void> start() async {
    running = true;
    final (_, server) = RpcChannelTransport.memoryPair();
    _onEndpoint(RpcResponderEndpoint(transport: server));
  }

  @override
  Future<void> stop({Duration? drainTimeout}) async => running = false;
}

void main() {
  test('WITNESS stop() during start() leaves no server running', () async {
    _Server? server;
    final module = _SlowModule();
    final app = RpcApp.server(
      modules: [module],
      server: (setup) => server = _Server(setup),
    );

    final starting = app.start();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await app.stop();
    await starting;

    expect(
      server?.running ?? false,
      isFalse,
      reason: 'start() went on to start a server after stop() returned',
    );
    expect(module.started, isTrue, reason: 'onStop ran before onStart ended');
    expect(module.stopped, isTrue);
  });
}
