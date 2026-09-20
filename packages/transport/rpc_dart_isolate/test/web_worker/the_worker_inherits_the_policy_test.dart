// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A web worker silently ran at the DEFAULT security policy.
//
// The VM sibling ships the spawner's policy as `args[4]` of `Isolate.spawn`
// (`policy.toMap()`) and the worker rebuilds it with `fromMap`. On web a
// `Worker` has no argument list, so nothing carried it:
// `runRpcIsolateManagerWorker` took `RpcSecurityPolicy policy = const
// RpcSecurityPolicy()` as a DEFAULT PARAMETER of the worker-side function,
// while `spawn(policy:)` applied the caller's only to the host transport.
//
// So a raised limit held on one side of the boundary and not the other, with no
// error anywhere: the host would accept a 64 MiB message and the worker refuse
// it at the stock 16 MiB, or the reverse.
//
// The URL is the one channel a Worker has at construction, so the policy rides
// on it. The two functions live OUTSIDE the `dart:js_interop` file precisely so
// this can exist: they are a PAIR, and the round trip they make crosses a
// Worker boundary no test can build.

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_isolate/src/worker_policy.dart';
import 'package:test/test.dart';

void main() {
  const raised = RpcSecurityPolicy(
    maxMessageLengthBytes: 64 * 1024 * 1024,
    maxActiveStreams: 999,
    maxMethodPathLength: 777,
  );

  test('the policy survives the worker URL round trip', () {
    final uri = withWorkerPolicy(Uri.parse('https://x/worker.js'), raised);
    final back = policyFromWorkerUrl(uri.toString());

    expect(back, isNotNull);
    expect(back!.maxMessageLengthBytes, raised.maxMessageLengthBytes);
    expect(back.maxActiveStreams, raised.maxActiveStreams);
    expect(back.maxMethodPathLength, raised.maxMethodPathLength);
  });

  // THE defect: without the carrier the worker fell back to stock limits, and
  // the difference is what a raised policy is FOR.
  test('a raised limit is not the default one', () {
    const stock = RpcSecurityPolicy();
    expect(
      raised.maxMessageLengthBytes,
      isNot(stock.maxMessageLengthBytes),
      reason: 'if these matched, the test above would pass on a broken carrier',
    );
  });

  test('an existing query parameter on the worker URL survives', () {
    final uri = withWorkerPolicy(Uri.parse('https://x/worker.js?v=7'), raised);

    expect(uri.queryParameters['v'], '7');
    expect(policyFromWorkerUrl(uri.toString()), isNotNull);
  });

  group('a URL that carries no usable policy yields null', () {
    // The worker then uses its explicit `policy:` argument, and failing that
    // the default -- which is the old behaviour, kept as the floor.
    test('no parameter at all', () {
      expect(policyFromWorkerUrl('https://x/worker.js'), isNull);
    });

    test('an empty value', () {
      expect(policyFromWorkerUrl('https://x/worker.js?rpcPolicy='), isNull);
    });

    // GUARD: a malformed value must not stop the worker booting. A worker that
    // throws here never comes up at all, which is worse than stock limits.
    test('GUARD: a malformed value does not throw', () {
      expect(
        () => policyFromWorkerUrl('https://x/worker.js?rpcPolicy=not-json'),
        returnsNormally,
      );
      expect(
        policyFromWorkerUrl('https://x/worker.js?rpcPolicy=%5B1%2C2%5D'),
        isNull,
      );
    });
  });
}
