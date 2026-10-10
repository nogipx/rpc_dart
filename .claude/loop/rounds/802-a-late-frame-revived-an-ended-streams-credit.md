---
round: 802
verdict: FIXED
packages: [rpc_dart]
lens: RPC-01
bench: P-293 — new
commit: yes
severity: S1
release: changelog
---

# Round 802 — a late frame revived an ended stream's credit

## Target

B-279, the next open lead the matrix filed: the server's flow-control state
stayed after calls that ended by deadline or failure, on the channel transport
and on isolate (built on it). Re-measured after round 801 first: still there.

## Hypothesis

A frame the peer sends after this side has dropped a stream's state rebuilds
that state, and nothing drops it again.

## Before

```
isolate | unary deadline         fc.sendCredit 0->1  messageCredit 0->1  advertised 0->1
isolate | 40 calls               sendCredit 0->3  messageCredit 0->3  advertised 0->5
channel | 40 calls               advertised 0->2
model isolate seed 5             0->5 each, 5 calls        <- one entry per call
model pinned (late send)         pendingGrant 0->1  pendingMessageGrant 0->1
isolate | unary completes        0                         <- control
```

Bench: the matrix, `P-293`. Instrumented (lib edits, removed after): every
re-created entry came from `_onMessage -> advertiseStream` for an id already
forgotten.

## Mechanism

Two halves. `_onMessage` advertised a window on the first frame it saw of an
id, and a late frame of an ended stream is a first frame to a set that has
forgotten it. The advertisement made the stream live again (`_isStreamLive`
counts advertised ids), so the peer's grants rebuilt its send and message
credit. Separately, `credit()` accumulated a pending per-stream grant for any
id, so a late payload credited on arrival left `pendingGrant` behind.

## Fix

`RpcChannelTransport` remembers the ids whose state it dropped, bounded and
oldest-first like `_finishedStreams`, and a frame for one does not advertise.
`createStream` clears a reused id. `RpcFlowController.credit` still returns the
connection's share for any id, and skips the per-stream grant for a stream
that is not live.

## After

```
I-5 rows above                   all at baseline, un-marked
lifecycle model                  every seed and pinned cell passes with the
                                 fc.* exclusion removed
```

## Canary

Both halves off: the 5 I-5 cells and 8 model seeds fail, e.g. `isolate | seed
5: gauges not back at baseline ... {fc.sendCredit: 0 -> 5, fc.messageCredit:
0 -> 5, fc.advertised: 0 -> 5}`. The credit half off alone: the pinned cells
on channel and isolate fail with `{fc.pendingGrant: 0 -> 1,
fc.pendingMessageGrant: 0 -> 1}`. Restored: 167 passed in the two files.

## The verdict questions

1. Yes: the control rows differ in the ending only.
2. Yes: 0->5 against 0.
3. On the server transport, its own `flowControlStateSizes`.
4. The control reads zero by the same gauges that read 5 on the case.
5. Quoted.
6. Two halves, two canaries.
7. From the table. S1: one entry per call ended this way, for the life of
   the connection.
8. B-279's S2/S1 question answered by measurement (the model's 5 for 5).
9. A set that admits an id on "first seen" readmits an id it has forgotten.
   Written into RPC-01's evidence; not a lesson, the lens already names the
   skip path.
10. Siblings below are rows of the same matrix, run before and after.
A1. Separate policies on each side (the harness's). A2. Latency: the late
    frame is real ordering, not a delay. L1. n/a.

## Gate

`melos run analyze`, `format:check`, `license:check`, `test:unit` (14
suites), `test:web` (15), `test:wasm` (53): green.

`pre_method_buffer_bounded_test` timed out on the first gate run: it awaited
200 sends to a stream id the server had already refused, which kept going
only because the server credited that dead stream. The test checks the
refusal; its sends are now not awaited, and it passes. The half that changed
it is the advertise guard (switched off alone, the test passed).

## Siblings

- channel: fixed here
- websocket: fixed here, built on the channel transport; its I-5 rows and
  model seeds passed before and pass after
- isolate: fixed here, built on the channel transport; the failing rows
  above now pass
- http: clean — no channel transport; the same I-5 rows and model seeds stay
  at baseline before and after
- http2: clean — its own flow control; the same rows and seeds stay at
  baseline
- wasm: clean — `test:wasm` 53 passed against the changed core; not in the
  matrix (outside the workspace)

## Not fixed

- A peer flooding a stream this side has ended now gets no more credit for
  it, so its sender parks there until it learns the call ended. That is the
  intended reading of "credit for a live stream only"; an rpc_dart caller
  learns it from the trailer and tears down, which wakes the send.
- The standalone core probe does not reproduce the residue over `pair` or
  `memoryPair` with the fix off; the reason it needs the matrix's harness
  (separate policies, real workers) is not measured.

## Links

Lens `../lenses/RPC-01-flow-control-credit-on-skip.md`. Bench
`../probes/P-293-ended-stream-flow-state-in-the-matrix.md`. Lead
`../backlog/B-279-flow-control-credit-left-on-the-server-after-some-endings.md`,
closed.
