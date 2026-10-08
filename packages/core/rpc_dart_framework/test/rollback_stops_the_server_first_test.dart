// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// stop() stops the server before the modules, so handlers still running can
// reach what the modules hold. Since modules start before the server, a start
// that fails in afterModulesStart has a server already up, and its rollback
// stopped the modules first, under that live server. It now keeps stop()'s
// order.

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_framework/rpc_dart_framework.dart';
import 'package:test/test.dart';

final _events = <String>[];

class _Module extends RpcServerModule {
  @override
  String get name => 'Db';

  @override
  Future<void> onStop() async => _events.add('module.onStop');

  @override
  List<RpcResponderContract> buildContracts(RpcContainer container) => const [];
}

class _Server implements IRpcServer {
  _Server(this._onEndpoint);
  final void Function(RpcResponderEndpoint) _onEndpoint;

  @override
  bool get isRunning => true;

  @override
  List<RpcResponderEndpoint> get endpoints => const [];

  @override
  Future<void> start() async {
    final (_, server) = RpcChannelTransport.memoryPair();
    _onEndpoint(RpcResponderEndpoint(transport: server));
  }

  @override
  Future<void> stop({Duration? drainTimeout}) async =>
      _events.add('server.stop');
}

final _codec = RpcCodec(RpcString.fromJson);

/// Serves one method and, in onStop, tries a call through the app: a call that
/// still succeeds means the endpoint served while the module was stopping.
class _ServingModule extends RpcServerModule {
  RpcTestApp? app;
  bool? servedDuringOnStop;

  @override
  String get name => 'Serving';

  @override
  Future<void> onStop() async {
    try {
      await app!.caller
          .unaryRequest<RpcString, RpcString>(
            serviceName: 'Svc',
            methodName: 'Echo',
            request: 'x'.rpc,
            requestCodec: _codec,
            responseCodec: _codec,
          )
          .timeout(const Duration(seconds: 2));
      servedDuringOnStop = true;
    } catch (_) {
      servedDuringOnStop = false;
    }
  }

  @override
  List<RpcResponderContract> buildContracts(RpcContainer container) => [
    _EchoContract(),
  ];
}

final class _EchoContract extends RpcResponderContract {
  _EchoContract() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'Echo',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (r, {RpcContext? context}) async => r,
    );
  }
}

void main() {
  setUp(_events.clear);

  test('WITNESS RpcTestApp.dispose closes the endpoints first', () async {
    final module = _ServingModule();
    final app = await RpcTestApp.start(modules: [module]);
    module.app = app;

    await app.dispose();

    expect(
      module.servedDuringOnStop,
      isFalse,
      reason: 'the endpoint still served while modules were stopping',
    );
  });

  test('WITNESS a failed start stops the server before the modules', () async {
    final app = RpcApp.server(
      modules: [_Module()],
      server: _Server.new,
      afterModulesStart: (_) async => throw StateError('hook failed'),
    );

    await expectLater(app.start(), throwsStateError);

    expect(_events, [
      'server.stop',
      'module.onStop',
    ], reason: 'the rollback stopped modules under a server still serving');
  });
}
