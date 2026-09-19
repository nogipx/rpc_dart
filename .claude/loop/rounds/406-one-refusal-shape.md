---
round: 406
verdict: FIXED
packages: [rpc_dart_websocket, rpc_dart_http2]
lens: RPC-25
bench: P-90 — reused
commit: yes
---

# Round 406 — one refusal shape, and the half that could not ship

## Target

B-61, which round 405 filed as an owner decision. The owner answered both
questions: unify the type across every transport on
`RpcStatusException(FAILED_PRECONDITION)`, and make the http2 caller enter the
disconnected state when its connection dies.

The first shipped. **The second did not, and the reason is the round's main
finding.**

## Hypothesis

Both halves are mechanical: change one throw per transport, and give http2 a
way to learn its connection died. Nothing in the way but the edit.

## Before

P-90 reused:

```
transport   health     createStream()   a unary call          isClosed
websocket   degraded   StateError       StateError            false
http2       degraded   no throw         RpcStatusException    false
```

## After

Both `_ensureUsable` implementations now throw
`RpcStatusException(RpcStatus.failedPrecondition, ...)` with the message
unchanged. Measured, websocket:

```
createStream()   RpcStatusException
a unary call     RpcStatusException
```

The code is the load-bearing part, not the type. It must be an
`RpcStatusException` so one `catch` covers every transport; it must NOT be
UNAVAILABLE, because `RpcRetryInterceptor._shouldRetry` takes only UNAVAILABLE
and RESOURCE_EXHAUSTED and never calls `reconnect()` — so a retry spins against
the same dead transport. FAILED_PRECONDITION is catchable and not retried, which
is the earlier round's argument preserved under a new type.

## Why the second half was reverted

Implemented as a derived predicate — `!isOpen && !goawayReceived && no active
streams` — because `_disconnected`'s only writers are the opt-in keepalive and a
failed `reconnect()`. Two existing tests then failed, and both encode a
deliberate decision that contradicts it:

```
test                                                   asserts
goaway_is_unavailable_test:
  "a drained connection is retried as the retry         UNAVAILABLE, RETRYABLE
   doc promises"
max_concurrent_streams_saturation_test:
  "GUARD: a genuinely dead connection still reports     createStream() SUCCEEDS,
   UNAVAILABLE and down"                                then UNAVAILABLE
```

The second is exactly the case B-61 named — an abruptly killed socket — and it
requires `createStream()` to hand out an id and the send to answer UNAVAILABLE.

So http2 does not "fail to notice" its connection died. It notices, and answers
**UNAVAILABLE and retryable** on purpose, on both endings. The websocket side
refuses **non-retryably**, also on purpose. The two transports disagree because
two rounds each made a defensible choice, and each pinned it with a test that
states the argument.

**B-61's premise was wrong**, and the round that found that out is this one. The
guard's reachability is not a bug to fix; it is the visible edge of a semantic
disagreement about whether a dead connection is worth retrying.

## Mechanism

A first attempt made it worse in an instructive way. The predicate dropped the
GOAWAY exemption — reasoning that with zero streams in flight a drained
connection is simply gone, which health's own message seems to support
(*"Reconnect is required; 0 call(s) still finishing"*). That is what broke
`a drained connection is retried as the retry doc promises`: health's three
branches distinguish cases for the MESSAGE, not for liveness, and one of them is
load-bearing for retry semantics.

> **A predicate lifted out of a reporting function inherits the report's
> distinctions, not the caller's.** health() splits draining from down to say
> different things; the send path splits them to decide whether a retry can
> work. Same condition, different purpose.

## Canary

`calls_during_reconnect_are_refused_test.dart` is updated rather than deleted,
and its matcher is now a PAIR — the type AND the status code:

```dart
final Matcher _refusedNotRetryable = throwsA(
  isA<RpcStatusException>().having(
    (e) => e.statusCode, 'statusCode', RpcStatus.failedPrecondition),
);
```

Asserting the type alone would let the code regress to UNAVAILABLE and stay
green, which is the defect that file was written for. The file says so.

## Gate

`melos run analyze` clean over 21 packages + wasm; `format:check` clean;
`license:check` compliant; workspace suite **SUCCESS in all 14 packages**,
rpc_dart_websocket **+177**, rpc_dart_http2 **+230**.

## Not fixed

**The behaviour is still not unified, only the type is** — and finishing it
needs the owner to overturn one of two tested decisions:

- http2: a dead or drained connection is UNAVAILABLE and retryable
- websocket: the disconnected state is refused non-retryably

B-61 is rewritten around that question instead of the one it was filed with.

## Links

- B-61 — premise corrected; the open question is now which retry semantics win
- P-90 — reused; the `health()` message column is what showed the GOAWAY branch
- RPC-25 — two siblings disagreeing, where BOTH choices were argued for
