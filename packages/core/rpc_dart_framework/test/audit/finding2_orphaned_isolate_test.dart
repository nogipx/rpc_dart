// Audit finding 2: isolates spawned before server start are orphaned if
// server.start() throws (e.g. port bind failure).
// Source: lib/src/rpc_app.dart:264-277 (_startServer): isolates are spawned in
// the loop at 266-271, THEN `await _server!.start()` at 275 can throw. The
// catch block in start() (140-144) does NOT terminate the spawned isolates.
//
// Repro: server.start() throws. After start() fails, the isolate module must
// have been torn down. We observe this via `isolateCaller`: terminateIsolate()
// sets _isolateCaller back to null, so a torn-down module throws StateError
// when isolateCaller is read. An orphaned (still-alive) caller returns fine.

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_isolate/rpc_dart_isolate.dart';
import 'package:rpc_dart_framework/rpc_dart_framework.dart';
import 'package:test/test.dart';

// Top-level entrypoint required by Isolate.spawn.
void _worker(IRpcTransport transport, Map<String, dynamic> _) {
  final endpoint = RpcResponderEndpoint(transport: transport);
  endpoint.start();
}

class _IsolateMod extends RpcIsolateModule {
  @override
  String get name => 'IsolateMod';
  @override
  RpcIsolateEntrypoint get workerEntrypoint => _worker;
  @override
  List<RpcResponderContract> buildProxyContracts(RpcCallerEndpoint caller) =>
      const [];
}

// Fake server whose start() throws, like a failed port bind.
class _ThrowingServer implements IRpcServer {
  @override
  bool get isRunning => false;
  @override
  List<RpcResponderEndpoint> get endpoints => const [];
  @override
  Future<void> start() async {
    throw StateError('port bind failed');
  }

  @override
  Future<void> stop() async {}
}

void main() {
  test('spawned isolate is terminated when server.start() throws', () async {
    final mod = _IsolateMod();
    final app = RpcApp.server(
      modules: [mod],
      server: (_) => _ThrowingServer(),
    );

    await expectLater(app.start(), throwsA(isA<StateError>()));

    // CORRECT behavior: the isolate should have been torn down -> reading
    // isolateCaller throws StateError ('isolate not started yet').
    // If it returns a live caller, the isolate is orphaned (CONFIRMED bug).
    expect(() => mod.isolateCaller, throwsA(isA<StateError>()),
        reason: 'isolate must be terminated after failed server start');

    // Best-effort cleanup so the test process can exit.
    try {
      await mod.terminateIsolate();
    } catch (_) {}
  });
}
