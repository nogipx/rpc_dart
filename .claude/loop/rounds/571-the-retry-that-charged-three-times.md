---
round: 571
verdict: FIXED
packages: [rpc_dart, rpc_dart_http2]
lens: RPC-08
bench: P-192 — new
budget: probes 1/5, canaries 1/5
commit: yes
release: breaking
severity: S1
---

# Round 571 — the retry that charged three times

## Target

`B-185`. Chosen over the rest of the http2 intake because its damage is the one kind that cannot
be undone by a later round: work re-executed. The lead's own framing — "non-idempotent work
retried after it ran" — names a count, so the probe counts server executions rather than reading
a status.

Scope decided first: `grep` for the synthesised status across every `lib/` found **two** sites —
the http2 caller's `onDone` the lead names, and core's `RpcChannelTransport`, which websocket,
isolate and in-memory inherit. Both measured, both fixed.

Lens RPC-08: one rule, two places, applied the same wrong way in each.

## Hypothesis

A peer that ends cleanly without trailers is reported UNAVAILABLE, which is precisely what
`RpcRetryInterceptor` retries, so a call that already ran is re-issued.

## Before

```
http2 caller
  WITNESS  no trailers, maxAttempts 3    status 14, the server ran it 3 time(s)
  ARM      no trailers, no retry         status 14, the server ran it 1 time(s)
  CONTROL  trailers sent, maxAttempts 3  returned "ok", 1 time(s)

core channel transport
  WITNESS  no status, maxAttempts 3      status 14, the peer served it 3 time(s)
  CONTROL  a status sent, maxAttempts 3  returned "ok", 1 time(s)
```

**Three executions of one unary call named `Charge`.** The ARM is what attributes it to the
retry rather than to the rig, and the CONTROL is what says the interceptor does not fire on a
healthy response. Probe:
`packages/transport/rpc_dart_http2/.dart_tool/probe/b185_missing_status.dart`.

## Mechanism

Both sites synthesised one status for two different endings. `_isTransient` retries UNAVAILABLE
by design — it is the "the connection died, try a fresh one" code — so using it for "the peer
answered and forgot its trailers" tells the retry layer that nothing ran.

## After

```
http2 caller    WITNESS  status 13, ran 1 time     CONTROL unchanged
core transport  WITNESS  status 13, served 1 time  CONTROL unchanged
```

**A split, not a replacement**, and the existing tests are what forced it:
`graceful_drain_on_stop_test` requires by name that a forceful `server.stop()` mid-call still
fails "with a prompt, classifiable, **retryable** status". That ending reaches the same branch.
So the status is chosen — `_drainSignal.goawayReceived || !_connection.isOpen` means the
connection is going away and UNAVAILABLE is right; a healthy connection ending a stream with no
trailers is INTERNAL, which is grpc-go's line too.

Both `server.stop()` tests passed the moment the split went in, having failed under the flat
replacement.

## Canary

```
`|| 1 > 0` forced onto the `dying` test

  a peer that forgets its trailers is not retried
    Expected: <1>
      Actual: <3>
    the request reached a server that RAN it; retrying re-issues work that may
    already have committed, which for a non-idempotent method is the whole of
    the damage
```

The canary reports the damage itself — three executions — rather than a status mismatch, which is
why the test asserts the count first and the status second.

## Six existing tests changed, and why that is not the fix papering over itself

`canary.md` item 9: read what a failing test measured before touching it.

- **`graceful_drain_on_stop_test`** names *retryable* as a requirement. **Not changed** — it is
  what produced the split.
- **`truncated_stream_is_an_error_test`** is also `server.stop()`, with no reason string on its
  status line. **Not changed**; it passes under the split.
- **`truncated_stream_without_trailers_test` (2), `unary_without_trailers_test`,
  `truncated_response_is_an_error_test` (2), `endpoint_ping_exchange_errors_test`** all measure
  that an ERROR is raised at all rather than a clean end — their reason strings say so, and one
  records `grpc-status=14` in a trace of what the code did. The value was incidental, and each now
  carries a line saying why it moved.

## Gate

```
melos run analyze                SUCCESS   21 packages + rpc_dart_wasm
melos run test:unit --no-select  SUCCESS   15 packages; rpc_dart_http2 +273,
                                           rpc_dart +1868 ~1
melos run format:check           SUCCESS   0 changed
melos run license:check          SUCCESS   2177 / 2177, REUSE compliant
```

## Not fixed

**The core site has no split.** `RpcChannelTransport`'s truncated end is always INTERNAL now,
because there is no `goawayReceived` equivalent there and no arm distinguishing a dying channel
from a forgetful peer. A channel that DIES mid-call surfaces through a different path (the
channel's own close), so the two are probably already separate — probably, not measured. If a
websocket peer can end a stream status-lessly *because* the socket is going, that case is now
non-retryable and this is where to look.

**`_isTransient`'s other retryable code is untouched.** RESOURCE_EXHAUSTED and transport-closed
are not in question here.

**The second terminal event is still emitted.** On a connection error `onError` reports
UNAVAILABLE and `onDone` then synthesises another ending, which is `B-189`'s subject; this round
changed what the second one says without removing it.

## Links

Lead `../backlog/B-185-http2-missing-status-is-retryable.md` — CLOSED.
Lead `../backlog/B-189-http2-terminal-events-are-delivered-twice.md` — the second ending this
round did not remove.
Bench `../probes/P-192-what-a-status-less-ending-costs.md` — new, both sites.
Lens `../lenses/RPC-08-policy-field-single-transport.md` — `applied: [571]`.
Lesson: none. `canary.md` item 9 is what carried this round — a failing test that names a
direction means a split — and it is already written.
