// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The transport server started BEFORE any module's onStart, so a connection
// arriving during startup ran buildContracts against a container whose
// onStart-provided resources did not exist yet. RpcTestApp did the same:
// contracts were built before onStart. Now every module starts first.
//
// Module health: a module reporting `closed` or `reconnecting` left the app
// `healthy`, because only `unhealthy` and `degraded` were read.

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_framework/rpc_dart_framework.dart';
import 'package:test/test.dart';

final _events = <String>[];

class _Resource {}

class _ResourceModule extends RpcServerModule {
  @override
  String get name => 'ResourceModule';

  @override
  Future<void> onStart(RpcContainer container) async {
    _events.add('onStart');
    container.registerSingleton(_Resource());
  }

  @override
  List<RpcResponderContract> buildContracts(RpcContainer container) {
    _events.add(
      'buildContracts(resource: ${container.tryGet<_Resource>() != null})',
    );
    return const [];
  }
}

/// Records when the app starts it, and builds one endpoint as a connection
/// would.
class _RecordingServer implements IRpcServer {
  _RecordingServer(this._onEndpoint);

  final void Function(RpcResponderEndpoint) _onEndpoint;
  final List<RpcResponderEndpoint> _endpoints = [];

  @override
  bool get isRunning => true;

  @override
  List<RpcResponderEndpoint> get endpoints => _endpoints;

  @override
  Future<void> start() async {
    _events.add('server.start');
    final (_, server) = RpcChannelTransport.memoryPair();
    final endpoint = RpcResponderEndpoint(transport: server);
    _onEndpoint(endpoint);
    _endpoints.add(endpoint);
  }

  @override
  Future<void> stop({Duration? drainTimeout}) async {
    for (final e in _endpoints) {
      await e.close();
    }
  }
}

class _HealthModule extends RpcModule {
  _HealthModule(this.level);

  final RpcHealthLevel level;

  @override
  String get name => 'HealthModule';

  @override
  Future<RpcHealthStatus?> checkHealth() async =>
      RpcHealthStatus(component: name, level: level);
}

void main() {
  setUp(_events.clear);

  test('WITNESS every module starts before the server accepts', () async {
    final app = RpcApp.server(
      modules: [_ResourceModule()],
      server: _RecordingServer.new,
    );
    await app.start();
    addTearDown(app.stop);

    expect(_events, [
      'onStart',
      'server.start',
      'buildContracts(resource: true)',
    ]);
  });

  test('WITNESS RpcTestApp starts modules before building contracts', () async {
    final app = await RpcTestApp.start(modules: [_ResourceModule()]);
    addTearDown(app.dispose);

    expect(_events, ['onStart', 'buildContracts(resource: true)']);
  });

  group('module health levels', () {
    for (final (moduleLevel, appLevel) in [
      (RpcHealthLevel.closed, RpcAppHealthLevel.unhealthy),
      (RpcHealthLevel.reconnecting, RpcAppHealthLevel.degraded),
      (RpcHealthLevel.unhealthy, RpcAppHealthLevel.unhealthy),
      (RpcHealthLevel.degraded, RpcAppHealthLevel.degraded),
      (RpcHealthLevel.healthy, RpcAppHealthLevel.healthy),
    ]) {
      test('${moduleLevel.name} makes the app ${appLevel.name}', () async {
        final app = await RpcTestApp.start(
          modules: [_HealthModule(moduleLevel)],
        );
        addTearDown(app.dispose);

        expect((await app.health()).level, appLevel);
      });
    }
  });
}
