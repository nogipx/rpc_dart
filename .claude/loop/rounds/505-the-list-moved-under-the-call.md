---
round: 505
verdict: FIXED
packages: [rpc_dart]
lens: RPC-16
bench: P-143 — new
commit: yes
---

# Round 505 — the list moved under the call

## Target

The middleware loops in `endpoint/base_endpoint.dart` — twenty-first in the audit's
rank.

Lens RPC-16, *check before await*. Its usual shape is a condition tested before a
suspension and relied on after it. This is the same suspension with a different thing
going stale across it: not a flag but the ITERATOR. `for (final m in _middlewares)`
awaits in its body, and a Dart `List` iterator refuses to continue if the list's
length changed — so the state that must survive the await is the collection itself.

## Hypothesis

`close()` clears the middleware list and `addMiddleware` appends to it, so either
during an in-flight call throws `ConcurrentModificationError` into that call.

## Before

One middleware parked 200 ms, disturbed at 100 ms:

```
CONTROL nothing disturbs it      OK echo:x
close() while parked             ConcurrentModificationError (length:0)
addMiddleware while parked       ConcurrentModificationError (length:2)
CONTROL close(), no middlewares  OK echo:x
```

Bench: `packages/core/rpc_dart/.dart_tool/probe/b114_middleware_list_mutated.dart`

**CONFIRMED on both routes, exactly as the lead described.** The damage is the error
TYPE: `ConcurrentModificationError` is a `StateError`, so a call that should have
reported "the endpoint is closing" reported a library bug instead.

The second control is what makes the table diagnostic rather than merely alarming.
With zero middlewares the loop never awaits, so `moveNext()` is never called a second
time and the mutation cannot be seen — which pins the defect to the iteration and not
to `close()` being called during a call. Without it, "close() breaks an in-flight
call" reads the table equally well, and the fix would have been aimed at `close()`.

## Mechanism

```dart
for (final middleware in _middlewares) {
  current = await Future<TRequest>.value(...);   // <- suspends here
}
```

`close()` does `_middlewares.clear()`, `addMiddleware` does `_middlewares.add(...)`,
and both are public. One middleware is enough: the loop enters, awaits, and the
`moveNext()` that ends the loop is the one that compares modification counts.

`.reversed` on a `List` is a lazy view of the same list, not a copy, so the response
half carried the identical defect and needed the identical fix.

## After

```
CONTROL nothing disturbs it      OK echo:x
close() while parked             RpcCancelledException: Endpoint closed
addMiddleware while parked       OK echo:x
CONTROL close(), no middlewares  OK echo:x
```

`List.of(...)` in both loops, guarded by an `isEmpty` early return so a call with no
middleware — the overwhelmingly common case — takes no per-call allocation for a copy
of an empty list.

**The `close()` row still fails, and it must.** The endpoint is closing and the call
cannot succeed; what changed is that it fails with its own status. A round that had
asked "does the call succeed" would have scored this fix as no change at all. The
`addMiddleware` row now succeeds, which is the sane reading of that operation: a
middleware added after a call started does not apply to it.

Regression: `test/endpoint/the_middleware_list_may_change_mid_call_test.dart`,
2 WITNESS and 3 GUARD.

## Canary

Both snapshots removed in place. Both WITNESS arms fail:

```
close() while parked        Expected: not 'ConcurrentModificationError'
                             Actual: 'ConcurrentModificationError'
addMiddleware while parked  Expected: 'OK echo:x'
                             Actual: 'ConcurrentModificationError'
```

All three GUARDs stay green. The third is the one that earns its place: it reads the
ORDER two middlewares run in, `[req:a, req:b, res:b, res:a]`. A snapshot is one edit
from a snapshot built wrong — empty, or reversed on the request half — and nothing
else in the file would notice.

## Gate

`melos run analyze` SUCCESS over 21 packages plus rpc_dart_wasm;
`melos run test:unit --no-select` SUCCESS; `melos run license:check` compliant.
`format:check` failed once on this round's own new test file and passed after
`fvm dart format`.

## Not fixed

**The interceptor list is also cleared by `close()`, and needs no fix.** Checked by
reading rather than measured, so the reasoning is recorded: those four loops build
the `next` chain synchronously — there is no `await` in the loop body, only inside the
closures they create — so the list cannot change between two `moveNext()` calls. This
is the reason the fix is two lines and not six.

**A middleware added mid-stream still applies to later messages of the same call.**
`_applyRequestMiddlewaresToStream` calls the snapshotting function once per message,
so each message re-reads the list. That is the previous behaviour preserved, not a
decision this round made, and nothing measured it either way.

**`close()` clearing the lists at all is left alone.** It happens before the transport
is closed, and the sequencing question — whether an endpoint should drop its
middleware before draining in-flight calls — is a wider design point than this
defect. Snapshotting makes the answer not matter for correctness.

## Links

Lens RPC-16 (extended: the thing that goes stale across the await can be the
collection). Bench P-143 (new). Lead B-114 (closed).
