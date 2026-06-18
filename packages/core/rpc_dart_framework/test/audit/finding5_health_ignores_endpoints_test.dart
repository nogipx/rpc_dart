// Audit finding 5: RpcApp.health() ignores endpoint health in overall level.
// Source: lib/src/rpc_app.dart:216-258. Endpoint metrics are collected at
// 237-240 but the overall `level` loop at 242-250 only iterates module health
// (`moduleHealth.values`); endpoint state never affects `level`. So an
// unhealthy/closed endpoint still yields RpcAppHealthLevel.healthy.
//
// Repro: a server exposing one endpoint whose transport is closed/inactive
// (metrics report isActive:false, transportClosed:true) and NO module health.
// Correct behavior: overall level should NOT be `healthy`.

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_framework/rpc_dart_framework.dart';
import 'package:test/test.dart';

class _NoopModule extends RpcModule {
  @override
  String get name => 'NoopModule';
  // No checkHealth override -> contributes nothing to module health.
}

class _ServerWithUnhealthyEndpoint implements IRpcServer {
  final RpcResponderEndpoint _ep;
  _ServerWithUnhealthyEndpoint(this._ep);
  @override
  bool get isRunning => true;
  @override
  List<RpcResponderEndpoint> get endpoints => [_ep];
  @override
  Future<void> start() async {}
  @override
  Future<void> stop() async {}
}

void main() {
  test('overall health reflects an unhealthy/closed endpoint', () async {
    final (clientT, serverT) = RpcInMemoryTransport.pair();
    final ep = RpcResponderEndpoint(transport: serverT);
    ep.start();
    // Close the endpoint so its metrics report unhealthy (isActive=false,
    // transportClosed=true).
    await ep.close();
    await clientT.close();

    final app = RpcApp.server(
      modules: [_NoopModule()],
      server: (_) => _ServerWithUnhealthyEndpoint(ep),
    );
    await app.start();
    addTearDown(app.stop);

    final report = await app.health();

    // Sanity: the endpoint metrics indeed reflect a dead endpoint.
    expect(report.endpoints, isNotEmpty);
    final m = report.endpoints.first;
    expect(
      m['isActive'] == false || m['transportClosed'] == true,
      isTrue,
      reason: 'endpoint metrics should show a closed/inactive endpoint',
    );

    // CORRECT behavior: a dead endpoint must not yield overall `healthy`.
    expect(
      report.level,
      isNot(RpcAppHealthLevel.healthy),
      reason: 'overall level must factor in unhealthy endpoints',
    );
  });
}
