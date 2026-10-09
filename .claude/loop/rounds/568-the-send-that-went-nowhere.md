---
round: 568
verdict: FIXED
packages: [rpc_dart_http2]
lens: RPC-17
bench: P-187 — reused
budget: probes 0/5, canaries 2/5
commit: yes
release: breaking
severity: S2
---

# Round 568 — the send that went nowhere

## Target

`B-221`, items 1 and 2 — the two readings round 565 took while measuring something else and did
not vary. Finishing what the previous round opened, and the lead named the first arm it needed:
the server's received frames, which the transport's own maps cannot answer. Item 3 (`_waiters`
overtaken by a new `add`) is untouched and stays on the lead.

Bench `P-187` reused and extended with a frame scanner rather than rebuilt.

Lens RPC-17: a ledger whose growth nothing watches — and, for item 1, the sibling question of a
success nothing checks.

## Hypothesis

A parked send woken by a peer RST_STREAM returns normally, so a payload that never left the
process reads as sent; and the inline release leaves the outgoing pump behind.

## Before

```
WITNESS  reset lands while the endStream send is parked
parked=true threw=null
    after reset  {activeStreams: 0, pendingSubscriptions: 0, pendingParsers: 0,
                  halfClosedLocal: 0, fcOutstanding: 0, outgoingPumps: 1,
                  streamControllers: 0}
    DATA frames the server read  [(64, false)]

CONTROL  window opens first, so the send completes BEFORE it
parked=true threw=null
    DATA frames the server read  [(64, false), (453, false), (517, true)]
```

**The 512-byte payload never reached the wire and the send reported success.** The server read
64 bytes — the window's worth of the FIRST send — and nothing else. The control, differing only
in a WINDOW_UPDATE before the reset, shows all three frames arriving, so the rig does deliver
payload when the stream is alive.

**And of the seven per-stream maps `health()` reports, `outgoingPumps` is the only one the
inline release leaves behind** — read together rather than one at a time, because fixing the map
one happened to look at is how the asymmetry survived (`L-12`).

Probe: `packages/transport/rpc_dart_http2/.dart_tool/probe/b184_halfclosedlocal_leak.dart`.

## Mechanism

A peer RST_STREAM cancels the pump's SINK — package:http2 tears the stream down — without
disposing the pump. Round 558's throw is gated on `_disposed || _controller.isClosed`, and
neither holds, so the woken `add` queues its payload into a controller whose destination is
already gone, closes it, and returns. `releaseStreamId` was the only teardown path that disposed
a pump, so the inline release kept one for every stream that ended any other way.

## After

```
WITNESS  parked=true threw=RpcStatusException
    after reset  every one of the seven maps 0
    DATA frames the server read  [(64, false)]          unchanged

CONTROL  parked=true threw=null
    DATA frames the server read  [(64, false), (453, false), (517, true)]
                                                         unchanged
```

Two mechanisms. `onCancel` on the pump's controller now records that the SINK let go — distinct
from `_finish()` closing it from this side, which `isClosed` already covers — and `add` throws on
it, the same `UNAVAILABLE` round 558 chose. The inline release disposes the pump.

**The control is what says the signal discriminates**: `onCancel` does not fire on a clean
completion, so a send that DID reach the peer still reads as success. Without that arm this would
be a fix that fails every parked send.

## Canary

Two, one per half, and each fails only its own test.

```
A. `_sinkCancelled && 1 < 0`
     a parked send fails when the peer resets the stream
       Expected: <Instance of 'RpcStatusException'>
         Actual: <null>

B. `if (1 < 0) _outgoingPumps.remove(streamId)?.dispose()`
     the inline release disposes the stream pump too
       Expected: <0>
         Actual: <1>
```

The other three tests pass under each, which is what says neither half masks the other's witness
(`L-01`).

## Gate

```
melos run analyze                SUCCESS   21 packages + rpc_dart_wasm
melos run test:unit --no-select  SUCCESS   15 packages; rpc_dart_http2 +265
melos run format:check           SUCCESS   0 changed
melos run license:check          SUCCESS   2169 / 2169, REUSE compliant
```

## Not fixed

**`_fcForget` is still not called on the inline release path**, where `releaseStreamId` calls it.
`fcOutstanding` read 0 in every arm, so there is no observable leak to witness and nothing was
changed on the strength of symmetry alone — the rule this journal keeps relearning is that a fix
without a failing arm is not proven. Named here so the next reader does not have to re-derive the
asymmetry.

**Item 3 of `B-221` is untouched**: `_waiters` can be overtaken by a new `add`. The lead says
what it needs first — a caller that can reach one pump concurrently at all, which no shape in
this repo does, since sends go through `base_processor`'s `_sendSequence`.

**The web/node target was not run.** This is `rpc_dart_http2`, which is `dart:io`-only, so there
is no dart2js arm to run; stated rather than left implicit.

## Links

Lead `../backlog/B-221-a-parked-send-reports-success-after-a-peer-reset.md` — items 1 and 2
CLOSED, item 3 open, so the lead stays open.
Round `565-the-canary-that-reported-a-pass.md` — where both readings were taken and filed.
Round `558-the-half-close-overtook-the-payload.md` — the rule item 1 extends, and the arm that
could not reach this path.
Bench `../probes/P-187-does-a-release-during-a-parked-send-leak-its-id.md` — reused, plus a DATA
frame scanner and all seven maps.
Lens `../lenses/RPC-17-limit-fires-after-residency.md` — `applied: [568]`.
Lesson: none. `L-01` and `L-12` are what this round applied, and both already carry it.
