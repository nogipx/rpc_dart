---
round: 574
verdict: FIXED
packages: [rpc_dart]
lens: RPC-20
bench: P-195 — new
budget: probes 1/5, canaries 2/5
commit: yes
release: changelog
severity: S2
---

# Round 574 — the grant nobody was listening for

## Target

`B-173`, chosen because it is the same defect already fixed in the isolate and wasm bridges, still
sitting in the PUBLIC in-memory channel — and because it maps onto a confirmed lens rather than
needing a new reading. The lead named its own witness precisely.

Lens RPC-20: the window before the first listener.

## Hypothesis

`_incomingCtl` is a plain broadcast fed from the constructor, so a frame arriving before the
transport subscribes is dropped — including the connection-window grant the peer sends from its own
constructor.

## Before

```
WITNESS  pair(), one turn between the two ends
    client credit  67108864
    server credit  null

ARM      pair(), no gap
    client credit  67108864
    server credit  67108864

CONTROL  memoryPair(), both ends in one expression
    client credit  67108864
    server credit  67108864
```

**`server credit null`** — the side built second never received the first's grant, so its flow
control is off in that direction for the life of the connection. One event-loop turn is the whole
difference. Probe:
`packages/core/rpc_dart/.dart_tool/probe/b173_direct_channel_drops.dart`.

**The ARM and the CONTROL are the same reading twice over**, which is the lead's point: `memoryPair`
is safe only because it builds both ends in ONE expression, and nothing about `pair()` promises that
to anyone else.

## Mechanism

`StreamController.broadcast(sync: true)` discards what it is given when no listener is attached, and
`RpcChannelTransport` advertises its connection window from its constructor — before whoever owns the
other end has subscribed.

## After

```
WITNESS  client 67108864, server 67108864
ARM, CONTROL  unchanged
```

`BufferedBroadcastController`, which is what `RpcFrameMultiplexedChannel` already uses: it buffers
while no listener is attached and flushes on the first `onListen`, bounded at 4096 events and 16 MiB.

`sizeOf` is `bufferedBytes`, which is **0 for a `directPayload` by definition** — queuing one costs a
pointer — so the count bound is the only one that binds on this channel. That is `B-217`'s
observation showing up in a third place, and it is stated rather than worked around.

## Canary

```
A. `maxPendingEvents: 0`
     Expected: not null
       Actual: <null>
     the arm needs both advertisements to have happened

B. the plain `StreamController.broadcast(sync: true)` restored
     Expected: not null
       Actual: <null>
     the client advertises its window from its own constructor, and a side that
     never receives that grant has flow control off in that direction for the
     life of the connection
```

**A is recorded because it ablates too MUCH and that was worth knowing**: with no buffer at all even
the client loses its own inbound grant, so it fails on the first assertion rather than the one under
test. B is the faithful switch-off — the original controller, in place — and it fails exactly on the
server's lost grant with both controls green.

## Gate

```
melos run analyze                SUCCESS   21 packages + rpc_dart_wasm
melos run test:unit --no-select  SUCCESS   15 packages; rpc_dart +1871 ~1
melos run format:check           SUCCESS   0 changed
melos run license:check          SUCCESS   2186 / 2186, REUSE compliant
```

**The first `test:unit` run was RED and the failure is named**: `rpc_notify`'s
`stream_distributor_test`, "Автоматическая очистка неактивных стримов", `Expected: <2> Actual: <0>`.
Not this change — `rpc_notify` references neither `RpcDirectMultiplexedChannel` nor `memoryPair`
anywhere, the test passes alone, and it asserts a timer-based cleanup whose own log shows a ~29 ms
inactivity window. `load averages: 22.29 17.51 13.57`, past the threshold `config.md` names. The
re-run was green across all 15.

**The swap drops `sync: true`**, so delivery on this channel is now asynchronous. That is a real
behaviour change and the suite is what establishes nothing depended on it: 15 packages green,
including every test built on `memoryPair`.

## Not fixed

**No arm drives the buffer's BOUNDS.** 4096 events and 16 MiB are inherited from
`BufferedBroadcastController`'s defaults, and what this channel buffers is "the handful of frames
before the pipeline subscribes" — the same justification its doc already gives. A peer that could
hold a listener off indefinitely would be the case to measure, and nothing here does.

**The byte bound does not bind here at all.** A `directPayload` weighs 0, so only the count applies —
`B-217`'s subject on a third queue. Named, not fixed.

**The lead's other claim is untouched**: that this is "the defect fixed in isolate and wasm" was taken
on trust rather than re-read, since what mattered was whether it is present HERE.

## Links

Lead `../backlog/B-173-the-direct-channel-drops-frames-before-subscribe.md` — CLOSED.
Lead `../backlog/B-217-the-connection-wide-buffer-has-no-depth.md` — the byte bound reading 0 for a
direct object, now on a third queue.
Bench `../probes/P-195-does-the-direct-channel-keep-early-frames.md` — new.
Lens `../lenses/RPC-20-the-window-before-the-first-listener.md` — `applied: [574]`.
Lesson: none. RPC-20 is this round, and `canary.md` item 1 — switch the fix off IN PLACE — is what
made canary A's over-ablation visible as the wrong arm.
