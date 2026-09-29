---
status: closed (round 505)
round: 505
commit: 0e5d6c1b
paths: [packages/core/rpc_dart/lib/src/endpoint/base_endpoint.dart]
probe: P-143
reason: "closed — CONFIRMED on both routes and fixed: close() and addMiddleware each threw ConcurrentModificationError into an in-flight call, so it failed with a StateError instead of its status. Both loops now iterate a List.of snapshot, behind an isEmpty early return"
---

# B-114 — middlewares are iterated across awaits while close() clears the list

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**high**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

`for (final middleware in _middlewares) { current = await ... }` — `close()` does `_middlewares.clear()` and `addMiddleware` appends; either during an in-flight call throws ConcurrentModificationError into that call.

## The shape

`packages/core/rpc_dart/lib/src/endpoint/base_endpoint.dart:264-292` (and `_middlewares.reversed`),
`close()` at `:223-249` clears both lists.

## Why it matters

A call in flight during `endpoint.close()` fails with a ConcurrentModificationError
instead of its status.

## Witness a round would build

Middleware that awaits 100 ms; start a call; `endpoint.close()` at 50 ms.

## Fix sketch

Snapshot the list (`List.of`) at call start.

## Outcome (round 505)

**CONFIRMED on both routes and fixed.** One middleware parked 200 ms, disturbed at
100 ms:

```
                                 before                        after
CONTROL nothing disturbs it      OK echo:x                     OK echo:x
close() while parked             ConcurrentModificationError    RpcCancelledException
                                 (length:0)                     'Endpoint closed'
addMiddleware while parked       ConcurrentModificationError    OK echo:x
                                 (length:2)
CONTROL close(), no middlewares  OK echo:x                     OK echo:x
```

Fixed as the sketch says — `List.of` in both loops — with an `isEmpty` early return so
the common no-middleware call takes no allocation. `.reversed` is a lazy view of the
same list, so the response half needed the same copy.

**The damage was the error TYPE.** A call interrupted by `close()` cannot succeed
either way; before it failed with a `StateError` from inside the library, after with
its own status. Worth noting because a test asking "did the call succeed" scores this
fix as no change.

**The second control localises it.** With zero middlewares the loop never awaits, so
`moveNext()` is never called a second time and the mutation cannot be observed —
without that arm, "close() breaks an in-flight call" explains the table equally well
and the fix gets aimed at `close()`.

**The interceptor list is also cleared by `close()` and needs no fix**, checked by
reading: those loops build the `next` chain synchronously, with awaits only inside the
closures they create, so the list cannot change between two `moveNext()` calls.

## Owner decision

—
