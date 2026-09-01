// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// RpcCallSpy records every call and each RpcSpyEntry holds the call's
// RpcContext, so an uncapped spy pins one context graph per call for the life
// of the process. Its own doc invited exactly that: "Attach to RpcTestApp or
// RpcApp" -- RpcApp being the production app class -- with no retention bound
// and no warning. maxEntries now caps it; the default stays unbounded so tests
// that assert on the full history keep working.

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_framework/rpc_dart_framework.dart';
import 'package:test/test.dart';

RpcMiddlewareContext _ctx(RpcCallerEndpoint endpoint, int i) =>
    RpcMiddlewareContext(
      endpoint: endpoint,
      serviceName: 'Svc',
      methodName: 'm$i',
      context: RpcContext.empty(),
    );

void main() {
  late RpcCallerEndpoint endpoint;

  setUp(() {
    final (client, _) = RpcChannelTransport.memoryPair();
    endpoint = RpcCallerEndpoint(transport: client);
  });

  Future<void> drive(RpcCallSpy spy, int count) async {
    for (var i = 0; i < count; i++) {
      await spy.interceptUnary<String, String>(
        _ctx(endpoint, i),
        'req',
        (ctx, req) async => 'ok',
      );
    }
  }

  test('maxEntries caps retention, keeping the most recent calls', () async {
    final spy = RpcCallSpy(maxEntries: 10);
    await drive(spy, 100);

    expect(spy.callCount, 10, reason: 'older entries must be dropped');
    expect(spy.entries.last.methodName, 'm99');
    expect(spy.entries.first.methodName, 'm90');
  });

  test('the default stays unbounded so tests see the whole history', () async {
    final spy = RpcCallSpy();
    await drive(spy, 50);

    expect(spy.callCount, 50);
    expect(spy.wasCalled('Svc', 'm0'), isTrue);
  });

  test('reset clears a capped spy too', () async {
    final spy = RpcCallSpy(maxEntries: 5);
    await drive(spy, 20);
    expect(spy.callCount, 5);

    spy.reset();
    expect(spy.callCount, 0);
  });

  test('maxEntries must be positive', () {
    expect(() => RpcCallSpy(maxEntries: 0), throwsA(isA<AssertionError>()));
  });
}
