---
round: 447
verdict: FIXED
packages: [rpc_dart_http2]
lens: RPC-25
bench: P-101 — new
commit: yes
---

# Round 447 — the same loss, on the other frame

## Target

B-86, next on the rank. Premise checked against the tree first: `git log` shows
nothing touching either HTTP transport's `lib/` since the lead's commit, and the
asymmetry is still there — `:1414` carries `&& statusKnown`, `:1344` does not.

Scope: the http2 caller's HEADERS path. NOT the HTTP/1.1 half, which the lead
itself records as unproven and which this round leaves unproven — said here
rather than discovered at the end.

## Hypothesis

A trailers frame that ends the stream and carries no grpc-status closes the
consumer before `onDone` can synthesise the UNAVAILABLE, so the consumer sees a
clean end after a partial response. Exactly what the DATA path's comment
describes, on the path without the guard.

## Before

```
              outcome                              transport trace
(d) DATA      status 14 after 2 items              end held back, then 14
(e) HEADERS   CLEAN END after 2 items, NO ERROR    end=true status=-, then 14
(f) control   CLEAN END after 2 items              end=true status=0
```

Probe: `packages/transport/rpc_dart_http2/.dart_tool/probe/missing_trailers.dart`
(round 429's file, two arms added) and
`packages/core/rpc_dart/.dart_tool/probe/clean_end_without_a_status.dart`.

**(e)'s trace reproduces the DATA path's documented failure line for line:**

```
payload=false end=true  grpc-status=-    <- closes the consumer
payload=false end=true  grpc-status=14   <- synthesised, too late
```

A reading trap worth keeping: `'${await run(x)}'` evaluates before its `say`, so
each arm's trace printed under the PREVIOUS arm's heading. The first reading of
(e) therefore appeared to show a status on the trailers frame. Label first.

## Mechanism

`_statusReceived` exists and the HEADERS path even MAINTAINS it — it adds to the
set two lines above, when the frame carries a grpc-status. It just never read it
back before setting the end flag. So the fix is not new state; it is using state
the same method already keeps.

## After

(e) reads `status 14 after 2 items`; the trailers frame is emitted with
`end=false` and the synthesised message becomes the ending. (d) and (f) unchanged.

## Canary

The guard switched off in place:

    Expected: 'status 14 after 2'
      Actual: 'clean end after 2'
    a trailers frame with no grpc-status ends the stream without ever saying
    how it went, so a clean end is the same silent data loss the DATA path was
    guarded against

`+2 -1`: round 429's witness and the conforming guard both stayed green, so the
new witness isolates the new defect.

## Gate

`melos run analyze` clean over 21 packages plus rpc_dart_wasm. `test:unit`
SUCCESS over 14 packages; `rpc_dart_http2` 241 passed, up one. `format:check` and
`license:check` SUCCESS. In the package: `analyze lib test` clean, full suite
241 passed with 0 failures.

## Not fixed

**The owner's decision was to put this check in CORE, once, for every transport,
and the measurement refuted that** — which is the one thing in this round worth
reading twice.

Core already raises. Measured over `RpcChannelTransport` in three variants — a
bare end-of-stream, a bare end with nothing delivered, and a trailers frame
carrying other headers but no status — all three give `RpcStatusException` with a
status-trailer control reading NO ERROR. So there is nothing to add at the
consumer boundary; the sub-shape that slips through is http2's own, because http2
emits a SECOND end-of-stream message carrying the synthesised status and the
first one had already closed the consumer.

The decision's stated benefit was that a core fix would cover the UNPROVEN
HTTP/1.1 half without having to prove it. That benefit is unavailable: if core
already refuses every ending it can see, an HTTP/1.1 defect of this shape would
have to be in HTTP/1.1's own emission too. **So the HTTP/1.1 half stays open and
unproven, and it is not covered by this round.** It needs its own arm on the
HTTP/1.1 trailer path; no lead is filed because B-86's own body already records
the question and the corrected version of the claim.

## Links

- RPC-25 — one rule, two paths, and only one of them carries it
- RPC-15 — the METHOD here: the record re-measured was an owner decision, and
  its `breaks:` says "on this project that is how data loss was found"
- P-101 — an ending with no status, per frame type; extends round 429's probe
- P-97 — the neighbouring shape (channel cut), which is how the core arm was
  framed
- B-86 — closed for http2 by this round; its HTTP/1.1 half stays open
- Round 429 — the DATA path, the guard this copies, and the test extended here
- L-13 — the owner's decision re-measured before being carried out, and refuted
