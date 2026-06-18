// Audit finding 1: RpcApp.start() has NO rollback on partial startup failure.
// Source: lib/src/rpc_app.dart:103-147 (start), specifically the try/catch at
// 128-144 which only sets `_started = false` and rethrows — it does NOT call
// onStop() on already-started modules, nor stop the server/isolates.
//
// Repro: module A starts successfully, module B.onStart throws. After start()
// fails, A.onStop MUST have been called for clean rollback. It is not.

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_framework/rpc_dart_framework.dart';
import 'package:test/test.dart';

class StartedModule extends RpcModule {
  bool onStopCalled = false;
  @override
  String get name => 'StartedModule';
  @override
  Future<void> onStart(RpcContainer container) async {}
  @override
  Future<void> onStop() async {
    onStopCalled = true;
  }
}

class FailingModule extends RpcModule {
  @override
  String get name => 'FailingModule';
  // Must start AFTER StartedModule -> declare dependency so sort orders it last.
  @override
  List<Type> get dependencies => [StartedModule];
  @override
  Future<void> onStart(RpcContainer container) async {
    throw StateError('boom in onStart');
  }
}

// Minimal fake server that starts fine; the failure comes from a module.
class _FakeServer implements IRpcServer {
  bool _running = false;
  @override
  bool get isRunning => _running;
  @override
  List<RpcResponderEndpoint> get endpoints => const [];
  @override
  Future<void> start() async {
    _running = true;
  }

  @override
  Future<void> stop() async {
    _running = false;
  }
}

void main() {
  test('start() rolls back already-started modules on later failure', () async {
    final started = StartedModule();
    final app = RpcApp.server(
      modules: [started, FailingModule()],
      server: (_) => _FakeServer(),
    );

    await expectLater(app.start(), throwsA(isA<StateError>()));

    // CORRECT behavior: the successfully started module must be stopped.
    expect(
      started.onStopCalled,
      isTrue,
      reason: 'StartedModule.onStop must be called during rollback',
    );
  });
}
