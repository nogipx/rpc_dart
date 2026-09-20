// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The two halves of one round trip disagreed about what a name may contain.
//
// `parseRpcMethodPath` explicitly admits a DOTTED service name -- its token
// pattern is `[A-Za-z0-9_.-]+`, and `myapp.v1.UserService` is the ordinary
// protobuf spelling. The formatter that turns `Service.Method` back into
// `/Service/Method` split on EVERY dot and demanded exactly two parts:
//
//   /myapp.v1.UserService/Get   ->  key myapp.v1.UserService.Get
//                               ->  split gives 4 parts, not 2
//                               ->  '/UnknownService/UnknownMethod'
//
// The damage is a diagnostic naming the wrong method, reachable by a peer that
// calls a dotted service -- not a routing failure, because `methodPath` rides
// on the frame and the formatter is only consulted when both retained messages
// are null. That is why it stood for two hundred rounds.
//
// The two rules now live side by side in `metadata.dart`, which is the point:
// an inverse pair that cannot be read together is an inverse pair that drifts.

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

/// Parse, then format. Both halves are the REAL ones.
String? _roundTrip(String methodPath) {
  final parsed = const RpcSecurityPolicy().parseMethodPath(methodPath);
  if (parsed == null) return null;
  return rpcMethodPathFromKey('${parsed.$1}.${parsed.$2}');
}

void main() {
  test('a dotted service name survives the round trip', () {
    expect(
      _roundTrip('/myapp.v1.UserService/Get'),
      '/myapp.v1.UserService/Get',
    );
  });

  // CONTROL: the single-dot form is what always worked, and must keep working.
  test('CONTROL: a plain service name still round-trips', () {
    expect(_roundTrip('/UserService/Get'), '/UserService/Get');
  });

  // The pair, stated as the property rather than as examples: the formatter
  // must be able to rebuild everything the parser admits.
  test('the formatter rebuilds exactly what the parser accepts', () {
    const policy = RpcSecurityPolicy();
    for (final path in [
      '/UserService/Get',
      '/myapp.v1.UserService/Get',
      '/a.b.c.d.e/F',
      '/Svc-1/Method_2',
    ]) {
      expect(
        policy.parseMethodPath(path),
        isNotNull,
        reason: 'the parser admits "$path"',
      );
      expect(
        _roundTrip(path),
        path,
        reason: 'so the formatter must rebuild it',
      );
    }
  });

  // GUARD: a key with no usable split is still reported as unknown rather than
  // producing a malformed path. These keys the parser would never yield.
  test('GUARD: a key with no usable split is still Unknown', () {
    expect(rpcMethodPathFromKey('NoDotHere'), '/UnknownService/UnknownMethod');
    expect(
      rpcMethodPathFromKey('.LeadingDot'),
      '/UnknownService/UnknownMethod',
    );
    expect(
      rpcMethodPathFromKey('TrailingDot.'),
      '/UnknownService/UnknownMethod',
    );
  });
}
