---
round: 244
verdict: CLEAN
packages: [rpc_dart]
lens: RPC-09
bench: none
commit: no
---

# Round 244 — the parked sender still wakes

## Target

RPC-09, `swept here (round 221, 7d06201c)`, six files moved since — and the
moved set includes `channel_transport.dart`, which round 240 edited, and
`client_connection.dart`, which rounds 240 and 242 both edited. A hang that
never ends is the damage class, so a re-sweep here is worth more than one on
RPC-05 or RPC-14 (four files each).

The round opened intending to ATTACK ROUND 240'S OWN FIX: `_msgCtl` became a
`BufferedBroadcastController`, which also buffers between listeners and drops
past 4096 events / 16 MiB, and a dropped response frame is a call that never
completes. That hypothesis dissolved on the first check and is recorded below
rather than quietly dropped.

## Hypothesis

Code added since 7d06201c leaves a sender parked with nothing left to wake it,
or introduces an await on a send that precedes waiting for the reply.

## Before

```
files moved under the lens's paths since the sweep    6
parking sites (`_fcAwaitCredit`)                      1
its wake paths                                        3   credit, grace timer, close
wake paths broken by anything since 7d06201c          0
```

`close()` walks `_fcSendWaiters` and wakes every one (`channel_transport.dart`
615-618) before it touches anything else; round 240's `_idManager.releaseAll()`
lands twelve lines later and does not reach the waiters. The legacy grace timer
that rescues a sender whose peer never grants is untouched. No bench: the
detector yields one parking site, and the question is which wake paths reach it.

## Mechanism

n/a — nothing found.

## After

n/a

## Canary

n/a. Worth naming what stands in for one: the wake-on-close is not merely read
here, it carries its own recorded ablation — removing it stops the send loop for
good, `TimeoutException` after 5 s, measured in
`close_during_traffic_test` in rpc_dart_websocket. That is the property this
sweep checked is still wired, and unlike round 243's trailer caps it has a
witness that would go red.

## Gate

Nothing shipped; the tree at 8d4d1e33 is green.

## Not fixed

**The hypothesis this round opened with was wrong, and the reason is worth
keeping.** Before round 240, `_msgCtl` was a plain broadcast: it dropped
EVERYTHING that arrived while unlistened. The buffered controller drops only
past 4096 events or 16 MiB. So round 240 strictly reduced this hazard rather
than introducing one, and "attack your own fix" here found the fix already
smaller than what it replaced. Checking cost one comparison; assuming would have
cost a round.

What remains open is older than any of this and already filed: a parked sender
outliving its own call (B-13), which is a leaked completer rather than a hang.

## Links

Lens RPC-09, re-swept: status moves to `swept here (round 244, 8d4d1e33)` ·
refines catalog U-16 · B-13 is the piece it leaves open · the ablation it
leans on lives in rpc_dart_websocket's `close_during_traffic_test`.
