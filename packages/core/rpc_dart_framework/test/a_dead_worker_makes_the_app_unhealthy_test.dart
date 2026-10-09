// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A worker isolate behind an RpcIsolateModule is not restarted when it dies,
// so every call to it fails from then on. health() is how a supervisor finds
// that out, and it must say so.

import 'dart:isolate';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_framework/rpc_dart_framework.dart';
import 'package:rpc_dart_isolate/rpc_dart_isolate.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

void _worker(IRpcTransport transport, Map<String, dynamic> _) {
  final endpoint = RpcResponderEndpoint(transport: transport);
  endpoint.registerServiceContract(_WorkContract());
  endpoint.start();
}

final class _WorkContract extends RpcResponderContract {
  _WorkContract() : super('Work');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'Echo',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (r, {RpcContext? context}) async => r,
    );
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'Die',
      requestCodec: _codec,
      responseCodec: _codec,
      handler: (r, {RpcContext? context}) async => Isolate.exit(),
    );
  }
}

class _Mod extends RpcIsolateModule {
  @override
  String get name => 'Worker';
  @override
  RpcIsolateEntrypoint get workerEntrypoint => _worker;
  @override
  List<RpcResponderContract> buildProxyContracts(RpcCallerEndpoint caller) =>
      const [];
}

Future<Object?> _call(RpcCallerEndpoint caller, String method) => caller
    .unaryRequest<RpcString, RpcString>(
      serviceName: 'Work',
      methodName: method,
      request: 'x'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    )
    .then<Object?>((r) => r.value, onError: (Object e) => e);

Future<void> _untilClosed(IRpcTransport transport) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!transport.isClosed) {
    if (DateTime.now().isAfter(deadline)) {
      fail('the worker transport never closed after the worker exited');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  test('WITNESS a worker that died makes the app unhealthy', () async {
    final mod = _Mod();
    final app = await RpcTestApp.start(modules: [mod]);
    addTearDown(app.dispose);

    expect(await _call(mod.isolateCaller, 'Echo'), 'x');
    await _call(mod.isolateCaller, 'Die');
    await _untilClosed(mod.isolateCaller.transport);

    final health = await app.health();
    expect(
      health.level,
      RpcAppHealthLevel.unhealthy,
      reason:
          'every call to the worker now fails, and health() said '
          '${health.level.name}',
    );
    expect(health.modules['Worker']?['level'], 'unhealthy');
  });

  test('GUARD a live worker leaves the app healthy', () async {
    final mod = _Mod();
    final app = await RpcTestApp.start(modules: [mod]);
    addTearDown(app.dispose);

    expect(await _call(mod.isolateCaller, 'Echo'), 'x');
    final health = await app.health();
    expect(health.level, RpcAppHealthLevel.healthy);
    expect(health.modules, isNot(contains('Worker')));
  });
}
