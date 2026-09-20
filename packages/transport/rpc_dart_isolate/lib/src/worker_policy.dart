// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:convert';

import 'package:rpc_dart/rpc_dart.dart';

/// Query parameter carrying the spawner's security policy to a web worker.
///
/// The VM sibling passes `policy.toMap()` as `args[4]` of `Isolate.spawn` and
/// the worker rebuilds it with `fromMap`. A `Worker` has no argument list, so
/// the URL is the one channel it has at construction — and without it the
/// worker silently ran at `const RpcSecurityPolicy()` while the host ran at the
/// caller's, so a raised limit held on one side of the boundary and not the
/// other, with no error anywhere.
const String kWorkerPolicyQueryParam = 'rpcPolicy';

/// Adds [policy] to [uri] so the worker can adopt it.
///
/// **Platform-agnostic on purpose.** These two are a PAIR, and the round trip
/// they make crosses a Worker boundary that no test can build — so keeping them
/// out of the `dart:js_interop` file is what lets anything check they agree.
Uri withWorkerPolicy(Uri uri, RpcSecurityPolicy policy) => uri.replace(
  queryParameters: {
    ...uri.queryParameters,
    kWorkerPolicyQueryParam: json.encode(policy.toMap()),
  },
);

/// The spawner's policy, read from a worker's own URL, or null when absent.
RpcSecurityPolicy? policyFromWorkerUrl(String href) {
  final raw = Uri.tryParse(href)?.queryParameters[kWorkerPolicyQueryParam];
  if (raw == null || raw.isEmpty) return null;
  try {
    final decoded = json.decode(raw);
    if (decoded is! Map) return null;
    return RpcSecurityPolicy.fromMap(decoded.cast<String, Object?>());
  } catch (_) {
    // A malformed value must not stop the worker booting: a worker that throws
    // here never comes up at all, which is worse than stock limits. The
    // explicit `policy:` argument and then the default still apply.
    return null;
  }
}
