// Audit finding 8: RpcApp._setupEndpoint swallowed buildContracts failures.
// Source: lib/src/rpc_app.dart _setupEndpoint — a generic catch around
// module.buildContracts(...) logged and swallowed the error, then called
// endpoint.start() unconditionally. Result: a live endpoint missing services,
// so clients get "method not found" instead of a startup failure.
//
// Repro: a server module whose buildContracts throws must abort start() with
// the ORIGINAL error, and the endpoint must NOT be started.

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_framework/rpc_dart_framework.dart';
import 'package:test/test.dart';

class _ContractError extends Error {
  @override
  String toString() => 'boom in buildContracts';
}

class FailingContractsModule extends RpcServerModule {
  @override
  String get name => 'FailingContractsModule';

  @override
  List<RpcResponderContract> buildContracts(RpcContainer container) {
    throw _ContractError();
  }
}

// Fake server that invokes the endpoint-setup callback during start(), exactly
// like a real transport: the callback creating/wiring endpoints runs inside
// start(), so an exception thrown there propagates out of start().
//
// `setupCompleted` records whether `_setupEndpoint` returned normally. The old
// code swallowed the buildContracts error and called endpoint.start(), so the
// callback always completed; the fix makes it rethrow, so it does NOT complete
// and endpoint.start() is never reached.
class _FakeServer implements IRpcServer {
  _FakeServer(this._onEndpoint);
  final void Function(RpcResponderEndpoint) _onEndpoint;

  bool _running = false;
  bool setupCompleted = false;
  RpcResponderEndpoint? endpoint;

  @override
  bool get isRunning => _running;

  @override
  List<RpcResponderEndpoint> get endpoints =>
      endpoint == null ? const [] : [endpoint!];

  @override
  Future<void> start() async {
    _running = true;
    final (_, serverTransport) = RpcInMemoryTransport.pair();
    final ep = RpcResponderEndpoint(transport: serverTransport);
    endpoint = ep;
    _onEndpoint(ep); // throws if buildContracts fails -> setup never completes
    setupCompleted = true;
  }

  @override
  Future<void> stop() async {
    _running = false;
  }
}

void main() {
  test(
      'buildContracts failure aborts start() with original error, '
      'endpoint not started', () async {
    late _FakeServer captured;
    final app = RpcApp.server(
      modules: [FailingContractsModule()],
      server: (onEndpoint) => captured = _FakeServer(onEndpoint),
    );

    await expectLater(app.start(), throwsA(isA<_ContractError>()));

    expect(captured.setupCompleted, isFalse,
        reason: 'endpoint setup (and endpoint.start()) must not complete '
            'when contracts failed');
  });
}
