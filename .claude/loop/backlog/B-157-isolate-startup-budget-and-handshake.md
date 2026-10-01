---
status: open (round 579 answered claims 1 and 3; claim 2 remains and has no failure to measure)
round: 579
commit: 513dfc6e
release: none
paths: [packages/transport/rpc_dart_isolate/lib/src/isolate_transport.dart]
probe: P-200
reason: "cost — what is left is claim 2, a second handshake round trip on a path that runs once per isolate, with no failure to measure. Claim 1 is REFUTED (1.00x, not 2x) and claim 3 confirmed by reading and fixed as prose"
---

# B-157 — isolate: startup can take twice startupTimeout, over a handshake with a spare port; the kill comment has the order backwards

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**medium**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

Two phases each get the full `startupTimeout` (`:424`, `:552`); the worker replies with a SendPort and the host then sends a second port in an `init` message where one would do; `killIsolate`'s comment says the close frame goes out first, but `RpcChannelTransport.close()` awaits `_channelSub.cancel()` before closing the channel, so the frame follows the kill.

## The shape

`packages/transport/rpc_dart_isolate/lib/src/isolate_transport.dart:262, 312, 424, 443-451, 552, 569-577`.

## Why it matters

A 30 s default is really 60 s; an extra round trip and state to clean up; a
comment that describes an order that never happens (and an unawaited close).

## Witness a round would build

Worker that stalls in its entrypoint: time to failure.

## Fix sketch

One budget across both phases; single handshake; fix or reorder the comment.

## Outcome (round 579) — claim 1 REFUTED, claim 3 confirmed by reading

`../rounds/579-the-budget-that-was-never-doubled.md`. Bench `P-200`.

```
a worker that stalls before `ready`
    budget  500ms -> failed after  521ms (1.04x)
    budget 1000ms -> failed after 1002ms (1.00x)
    budget 2000ms -> failed after 2002ms (1.00x)
```

**"A 30 s default is really 60 s" is false.** Both timeouts exist and are sequential, but **nothing a
caller controls can make the first one slow**: the worker's wrapper sends its `SendPort` as its very first
act, before a line of user code. So phase 1 costs the spawn itself and phase 2 gets the budget. The true
bound is `spawn + startupTimeout`.

**The budgets are left as they are, deliberately**: one deadline across both phases would make the
contract exact but has NO failing arm, since phase 1 cannot be made slow through the public API. Rounds
563 and 564 declined a one-line guard on that bar.

**Claim 3 holds.** `killIsolate` calls `hostTransport?.close()` without awaiting — `kill` is
`void Function()` — so it runs to `close()`'s first await (`_channelSub.cancel()`,
`channel_transport.dart:627`) and yields; `teardownConnection()` then kills the isolate synchronously and
the frame `_channel.close()` would send goes out afterwards. The comment claimed the opposite and now says
what happens, plus why it is a trade: making the frame go first means awaiting, which means `kill`
returning a `Future` — a public signature change.

**A rig note worth keeping**: a stall written as `Future.delayed(...).then(...)` schedules and RETURNS, and
`ready` is sent right after the entrypoint returns, so the first version read `0.00x` with nothing thrown —
a measurement whose subject never happened (`measurement.md` item 8). The stall must be synchronous.

### Claim 2 remains

The worker replies with a SendPort and the host then sends a second port in an `init` message where one
would do. An extra round trip on a path that runs once per isolate, with no failure to measure.

## Owner decision

—
