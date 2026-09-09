---
round: 212
verdict: FIXED
packages: [rpc_dart]
lens: RPC-01
bench: P-04 — reused
budget: probes 0/3, canaries 1/3
review: self — the session forbids the Agent tool unless the user asks, so the `loop.py review` prompt was answered in full against the record, the bench and the canary; approved 10 of 10
commit: yes
---

# Round 212 — a late grant resurrects a dead stream's credit

## Target

B-14, opened by round 211 with the mechanism unpinned and the next instrument
named. It also happens to be the lens `next` names, RPC-01: this is credit
bookkeeping that outlives the frame it belongs to.

## Hypothesis

Round 211 disproved the obvious theory (the woken sender re-seeding through
`_fcTryConsume`) by measurement and named `_fcOnGrant` as the remaining suspect:
it also writes `_fcSendCredit` and is not gated on the stream being live.

## Before

```
P-04, reused unchanged. 30 client-stream uploads, 64 KiB window, 8 MiB offered
per call, handler consumes nothing so the sender parks at 17 messages:

  CONTROL handler drains (never parks) : sendCredit  0
  CASE    handler consumes nothing     : sendCredit 30
```

Probe: `packages/core/rpc_dart/.dart_tool/probe/parked_waiters_drain.dart`,
plus `sendcredit_timeline.dart` for the ordering.

Instrumenting both hops settled it in one run:

```
  GRANT 1, GRANT 1, FORGET 1, FORGET 1, FORGET 1, FORGET 1, GRANT 1
```

The last grant lands after every teardown of that id.

## Mechanism

`_fcForget` clears the entry when the call ends. A peer grant for the same id
can arrive afterwards — ordinary, not hostile: the peer credits what it consumed
or discarded, and that crosses our teardown — and `_fcOnGrant` wrote it straight
back. Nothing removes it a second time, because `_fcForget` has already run.

The map is capped by `_fcCanTrack`, so this never grows without bound. What it
does instead is quieter, and is why it is worth fixing rather than filing: once
the cap fills with dead ids, `_fcCanTrack` refuses NEW ones, so no later stream
is seeded and `initialSendWindowBytes` stops applying to any of them. That seed
is what bounds a sender before the peer's first grant — 156.25 MiB against
4.05 MiB over a 20 ms link. Round 145 attacked the cap and it holds; its story
was a hostile ghost-id flood, and this is ordinary successful traffic reaching
the same ceiling.

The fix refuses a grant for a stream nothing else still tracks. `_fcIsLive`
reads the three places a live stream leaves a trace — `_activeStreams` for one
this side opened, `_fcAdvertised` for one the peer opened (set from the first
frame we saw), a per-stream controller while a consumer is bound — all of which
`_fcForget` clears. A stream that already HAS credit keeps taking grants, so a
live mid-flight stream is untouched.

## After

```
  CONTROL handler drains           : sendCredit 0
  CASE    handler consumes nothing : sendCredit 0
```

Every counter in `flowControlStateSizes` returns to zero in both arms.

## Canary

Gate removed from `_fcOnGrant`, against
`test/transports/flow_control_state_returns_to_zero_test.dart`:

    Expected: <0>
      Actual: <10>
    10 abandoned uploads left 10 send-credit entries for streams that have
    ended; the map is capped, so the cost is that the initial send window
    stops seeding new streams once it fills

and the whole-map guard failed the same way. The drained-upload GUARD stayed
green — those calls never park, so they never take the late-grant path, which is
what shows the witness isolates this defect.

## Gate

`melos run analyze` green; `melos run format:check` green;
`melos run test:unit --no-select` green across the workspace.

## Not fixed

Nothing in this round's scope. Separately, the owner revisited **B-12** and
chose not to revert round 208 but to replace it with real cooperative
backpressure on http2 — rpc-level `x-window-update` grants as
`RpcChannelTransport` already does, so the transport never stops reading and a
slow consumer is throttled rather than failed. Filed as B-15; it is a multi-round
job and does not belong inside this one.

## Links

Lead `../backlog/B-14-stale-sendcredit-per-abandoned-upload.md` — closed by this
round, mechanism pinned.
Lead `../backlog/B-15-rpc-level-grants-on-http2.md` — new, owner-decided.
Bench `../probes/P-04-parked-waiters-drain.md` — reused unchanged; its
`sendCredit` column is now zero in both arms, which is the fix.
Lens `../lenses/RPC-01-flow-control-credit-on-skip.md` — `applied: [206, 207, 208, 212]`.
Round `211-the-wake-is-load-bearing.md` — which found this and disproved the
first theory.
