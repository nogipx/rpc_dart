---
round: 389
verdict: FIXED
packages: [rpc_dart]
lens: RPC-25
bench: P-80 — new
commit: yes
---

# Round 389 — the call that never ended

## Target

The owner asked whether all three defects from their audit were fixed. They were
not: one of three. This round takes the third — B-55, the responder's
`responseSink` — because it is silent-wrong-answer severity and its only blocker
was a broken rig, not a design question. B-54 stays open; it needs a surface
change to `CallProcessor` and the cap is one round away.

RPC-25 for the fifth round running.

## Hypothesis

The owner's reading: `responseSink`'s `onError` logs and returns, so the source's
`onDone` follows with `finishReceiving()` and the client is told a clean **OK**
for a handler whose own source failed.

## Before

**The rig first.** Round 386's probe hung before its first arm reported, which
is why B-55 was filed unmeasured. The cause was the rig, exactly as suspected:
rebuilt on `bidirectional_coverage_test`'s pair — `RpcInMemoryTransport.pair()`
through `NoZeroCopyTransport`, low-level responder on stream id 1 — and both
control arms answered at once.

Measured, with an OVERALL deadline rather than a per-event one, because "it
never ends" had to be one of the answers the instrument could give:

```
arm                              what the client sees
source fails after 2 messages    2 payloads, NEVER ENDED
handler finishes cleanly         2 payloads, ended OK
handler calls sendError          2 payloads, status 13
```

Probe: `test/streams/response_sink_error_reaches_the_client_test.dart` (P-80).

**The reading was directionally right and the consequence is worse than
predicted.** The client is not told OK — it is told NOTHING, for ever. A first
version of the witness asserted only `isNot(contains('ended OK'))` and passed
against the unfixed tree, which would have recorded a fix for a defect that was
never there. The assertion was replaced with the exact string before anything
was changed.

## Mechanism

`addStream` does **not** close its target controller. So a source that fails
reaches `onError` — which logged and returned — and the controller stays open:
`onDone` never runs, `finishReceiving()` is never called, no trailer is ever
sent. The caller holds an open call and its state for the life of the process.

`ServerStreamResponder` is the sibling and has done the right thing all along:
when its handler throws it calls `wireStatusFor(error)` and
`_processor.sendError(...)`, then completes. The bidi responder's sink is the
copy that only logged.

## After

```
arm                              before                    after
source fails after 2 messages    2 payloads, NEVER ENDED   2 payloads, status 13
handler finishes cleanly         2 payloads, ended OK      unchanged
handler calls sendError          2 payloads, status 13     unchanged
```

## Canary

`if (1 > 0) return;` at the top of the new `onError` body:

```
WITNESS: the client is not told OK
  Expected: '2 payloads, status 13'
    Actual: '2 payloads, NEVER ENDED'
  the handler's source failed after 2 of its messages; the client must be told,
  not left waiting
```

Both GUARDs — the clean finish and the explicit `sendError` — stayed green under
it, so the witness isolates the new defect and the fix is not credited with the
paths that already worked.

## Gate

`melos run analyze` clean over 21 packages + wasm; `format:check` clean;
`license:check` 1489/1489; workspace suite **SUCCESS in all 15 packages**,
rpc_dart **+1561 ~1** (was +1558; +3 from the new witness file).

## Not fixed

**B-54**, the second of the owner's three: a bidi producer keeps running after
the call has ended, 11 -> 32. Its two cheap candidates are already refuted
(round 386) and what remains is a surface change — a `done` future on
`CallProcessor`, which the responder already has — too large to open with the
cap one round away.

**B-53's narrow half** stays where round 388 left it: a stream that was never
half-closed, where rpc_dart's own RST_STREAM is the only signal and the
dependency offers no way to know the peer has finished.

`payloadResponses`' unreachable grpc-status branch, which rode along in B-55, is
untouched: it is cosmetic, and removing it wants a test pinning
`_grpcStatusErrorTransformer` first.

## Links

- RPC-25 — the lens; `applied:` gains 389. Fifth round running; the sibling was
  `ServerStreamResponder` this time
- P-80 — the bench, rebuilt on a rig that works
- B-55 — closed by this round
- B-54 — the one of the owner's three still open
- Round 384 — the caller-side half of the same duty; round 386 — where B-55 was
  filed unmeasured, and why
- L-15 — an instrument that cannot express the answer reports the wrong one:
  here, a witness that could not say "never ended" passed on the broken tree
