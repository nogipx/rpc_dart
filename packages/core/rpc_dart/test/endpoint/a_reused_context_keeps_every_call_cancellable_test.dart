// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// One RpcContext built once -- to carry an auth header -- and passed to two
// concurrent calls gives both the same requestId. Each must still be counted,
// and reached by cancelMethod and by close(); one finishing must not untrack
// the other.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Slow extends RpcResponderContract {
  _Slow() : super('S');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'slow',
      handler: (r, {RpcContext? context}) async {
        final ms = int.parse(r.value);
        await Future<void>.delayed(Duration(milliseconds: ms));
        return r;
      },
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

void main() {
  late RpcCallerEndpoint caller;
  late RpcResponderEndpoint responder;

  setUp(() {
    final (client, server) = RpcChannelTransport.pair();
    responder = RpcResponderEndpoint(transport: server)
      ..registerServiceContract(_Slow())
      ..start();
    caller = RpcCallerEndpoint(transport: client);
  });

  tearDown(() async {
    await caller.close();
    await responder.close();
  });

  Future<String> call(String ms, RpcContext context) => caller
      .unaryRequest<RpcString, RpcString>(
        serviceName: 'S',
        methodName: 'slow',
        request: ms.rpc,
        requestCodec: _codec,
        responseCodec: _codec,
        context: context,
      )
      .then((_) => 'ok', onError: (Object e) => e.runtimeType.toString());

  for (final shared in [true, false]) {
    final label = shared ? 'one shared context' : 'CONTROL: a context each';
    RpcContext Function() contextFor() {
      final one = RpcContext.withHeaders({'authorization': 'Bearer x'});
      return shared
          ? () => one
          : () => RpcContext.withHeaders({'authorization': 'Bearer x'});
    }

    test('$label: cancelMethod reaches both calls', () async {
      final next = contextFor();
      final a = call('2000', next());
      final b = call('2000', next());
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(caller.collectEndpointMetrics()['pendingRequests'], 2);
      expect(caller.cancelMethod('S', 'slow'), 2);
      expect(await Future.wait([a, b]), [
        'RpcCancelledException',
        'RpcCancelledException',
      ]);
    });

    test('$label: one finishing leaves the other tracked', () async {
      final next = contextFor();
      final short = call('20', next());
      final long = call('2000', next());
      expect(await short, 'ok');

      expect(caller.collectEndpointMetrics()['pendingRequests'], 1);
      expect(caller.cancelMethod('S', 'slow'), 1);
      expect(await long, 'RpcCancelledException');
    });
  }
}
