---
round: 408
verdict: FIXED
packages: [rpc_dart]
lens: RPC-15
bench: P-92 — new
commit: yes
---

# Round 408 — three types outside the hierarchy

## Target

The owner's new goal: one typed error hierarchy across core and every
transport. L-12 first — count the class before changing any of it, because
333/334 fixed a sample and reported "~20 remain" against a real surface of ~200.

## The count

**199 throw sites** across core, the framework and the five transports:

```
 45 ArgumentError        22 RpcException          6 RpcDeadlineExceededException
 38 StateError           17 RpcStatusException    2 UnimplementedError
 31 FormatException      15 UnsupportedError      1 each: SocketException,
 11 TimeoutException      8 RpcFrameException            RangeError,
                                                         RpcCancelledException,
                                                         CircuitBreakerOpenException
```

131 of 199 (66%) are raw Dart errors — and **a mass rename would be wrong**.
`ArgumentError` for a genuine programming mistake is idiomatic Dart, and 25 of
the `FormatException`s are in `codec/special_cbor.dart`, where malformed input
is exactly what that type is for. The class that matters is narrower: library
DOMAIN concepts that sit outside the library's own hierarchy.

Declared types, all packages:

```
inside    RpcException -> RpcStatusException -> RpcRateLimitException
          RpcException -> RpcFrameException
outside   RpcCancelledException          implements Exception
          RpcDeadlineExceededException   implements Exception
          CircuitBreakerOpenException    implements Exception
transports  RpcWebSocketNonBinaryFrame   extends RpcException + IRpcAdvisoryChannelError
            RpcHttp2StreamError          not an Exception at all
```

## Hypothesis

Being outside the hierarchy costs nothing, because `wireStatusFor`'s doc says
so:

> `RpcCancelledException` and `RpcDeadlineExceededException` are not
> special-cased: they live in a `part` of the contracts library, which this file
> cannot import without a cycle, and the responder pipeline answers both with
> their own status long before an error is translated.

The cycle is a fact. The second clause is REASONING, and round 321's rule is
that a comment explaining a previous fix is a record, not evidence.

## Before

P-92, over a real socket, one method per error type. `wireStatusFor` is DEFAULT
DENY — only the hierarchy reaches a peer intact:

```
SUBJECTS
  cancelled        status 13  "Internal server error"
  deadline         status 13  "Internal server error"
CONTROLS
  rpcException     status 13  "RpcException: a library diagnostic"
  statusException  status  5  "no such shape"
  stateError       status 13  "Internal server error"
```

Refuted. **A handler throwing a cancellation is indistinguishable from one
throwing a foreign `StateError`.** gRPC has CANCELLED(1) and
DEADLINE_EXCEEDED(4) for exactly this, and a caller — or a retry interceptor
keying on status — cannot tell either from "the server blew up".

The controls are what make that readable: `rpcException` keeps its message,
`statusException` keeps status AND message, `stateError` is redacted. So the
mechanism is precisely "outside the hierarchy → default deny".

## Mechanism

The cycle named in the comment blocks `protocol.dart` importing
`context.dart` — the MAPPER importing the types. It does not block the types
extending the base: `contracts/_index.dart` already imports `RpcException`, in
its own `show` list. The fix direction was available all along.

So the fix is at the TYPE, not at the mapper: the three extend
`RpcStatusException` with the status gRPC has for them. `wireStatusFor` needed
no change at all, which is why the deny stayed exactly as strict.

## After

```
cancelled   status 13 "Internal server error"  ->  status 1  "handler cancelled"
deadline    status 13 "Internal server error"  ->  status 4  "Deadline ... exceeded"
```

Controls unchanged, `stateError` still redacted.

Two constructor details that are not cosmetic. `RpcException` and
`RpcStatusException` became `const` — additive, every non-const invocation keeps
working — because `RpcCancelledException` and `CircuitBreakerOpenException` were
already const and `const CircuitBreakerOpenException()` appears twice in its own
file. And the breaker keeps `retryAfter` in `toString()` rather than folding it
into the status message, because a const constructor cannot interpolate; its
rendered text is therefore byte-identical.

`RpcDeadlineExceededException` is the one that could not stay const, and nothing
is lost: its message interpolates a `DateTime`, which has no const constructor,
so `const RpcDeadlineExceededException(...)` was never constructible.

## Canary

`test/errors/one_hierarchy_test.dart`, seven tests, and four are GUARDs because
widening a hierarchy is exactly the change that can widen a security boundary:

- a foreign `StateError` and a `FormatException` are still redacted — the
  load-bearing one, since default-deny exists because internal state reached
  unauthenticated peers before it
- `on RpcCancelledException catch` still selects the specific type and not its
  sibling — `rpc_data` has four such sites, the retry interceptor two
- the const constructors are still const
- `toString()` is byte-identical

## Gate

`melos run analyze` clean over 21 packages + wasm; `format:check` clean;
`license:check` compliant; workspace suite **SUCCESS in all 14 packages**,
rpc_dart **+1573**. **No existing test needed changing** — subclassing preserves
`on X catch`, and `RpcRetryInterceptor` checks both types before its
`RpcStatusException` branch.

## Not fixed

The goal is not done; this is the first of its rounds. Still outstanding:

- **`RpcHttp2StreamError` is not an `Exception`** yet is pushed onto an error
  stream. That is why round 393 had to add `if (error is IRpcAdvisoryChannelError)
  return;`.
- **`RpcFrameException extends RpcException`, not `RpcStatusException`** — so
  the eight sites that throw it get INTERNAL with the message forwarded, when
  the framing limits have gRPC statuses of their own. B-58 is the same question
  at a different site and is awaiting the owner, so this is named, not touched.
- The raw `StateError` / `ArgumentError` sites: 83 of them, most correct as-is.
  They need the reachability split — programmer error versus a runtime condition
  a peer can cause — before any of them moves.

## Links

- RPC-15 — a reasoning comment re-measured, round 321's variant
- L-12 — count the class first; the count is in `## The count`
- P-92 — new
