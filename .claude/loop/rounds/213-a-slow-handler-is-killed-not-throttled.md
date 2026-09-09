---
round: 213
verdict: DEFERRED
packages: [rpc_dart_http2]
lens: RPC-01
bench: P-05 — new
budget: probes 0/3, canaries 0/3
review: self — the session forbids the Agent tool unless the user asks, so the `loop.py review` prompt was answered in full against the record and the bench; approved 9 of 10, Q6 is n/a (no fix, so no canary)
commit: no
---

# Round 213 — a slow handler is killed, not throttled

## Target

B-15 — an owner decision, which outranks every other rule in step 1. Its own
acceptance criteria name a witness that does not exist: "a NEW witness that a
slow consumer is now THROTTLED rather than failed, which is the thing being
bought. Without that last one the change is unverified." This round builds it
and records what it says today, because that number decides how big B-15 is.

## Hypothesis

The round-208 refusal was understood as a guard against a consumer that STOPS.
If that is right, a consumer that merely reads slowly is unaffected and B-15 is
a small job. If it is wrong — if nothing throttles the producer, so the backlog
grows at the RATE GAP — then any gap crosses the window given enough upload, and
B-15 is urgent as written.

## Before

```
3000 x 4 KiB uploaded (12 MiB, 3x the default 4 MiB window):

  fast : completed 'done',  15.4 s, consumed 3000 of 3000   <- control
  slow : FAILED RpcStatusException(8) "Request exceeds the un-consumed
         window (4197354 > 4194304 bytes)", 2.1 s, consumed 67 of 3000
  deaf : FAILED, same status, 1.8 s, consumed 0
```

Probe:
`packages/transport/rpc_dart_http2/.dart_tool/probe/slow_consumer_is_throttled.dart`
(P-05).

The `slow` handler does nothing wrong: it reads every message and takes 2 ms
over each. It is killed after 2.1 seconds having processed 67 of them.

## Mechanism

The hypothesis was wrong, and the owner's instinct was right. Round 208 removed
the pause, which was the only thing that slowed a producer down; the budget that
replaced it is a BACKLOG bound, not a stall detector. So the un-consumed backlog
grows at (producer rate - consumer rate), and for any positive gap it reaches
`flowControlWindowBytes` given a large enough upload. A 2 ms-per-message handler
against an unthrottled producer reaches 4 MiB in about two seconds.

So the round-208 trade is worse than it was recorded as being: it does not
merely fail stalled consumers, it fails ordinary slow ones, and the failure
scales with upload size rather than with misbehaviour.

## After

n/a — not fixed.

## Canary

n/a — no fix. The `fast` arm is the control and it completes 3000 of 3000, which
is what makes the `slow` failure attributable to the rate gap and not to the
volume.

## Gate

No code changed. `git diff` is empty; the gate is the one HEAD passed at 212.

## Not fixed

> **Superseded by the owner, round 214.** B-15 was closed unbuilt: the benefit did not
> justify porting core's flow control onto two transports. The behaviour this
> round measured therefore STANDS, and is recorded as accepted in
> `../checked/C-19-http2-refuses-a-slow-consumer.md`. The rest of this section is
> what was true when it was written; P-05 is no longer an acceptance test waiting
> to go green, it documents the accepted numbers.

The fix is B-15, already decided by the owner and scoped there, and it is
genuinely multi-round: rpc-level `x-window-update` grants emitted by the
responder as it consumes, and a caller that parks on that credit, for both
directions, with the round-208 refusal removed only once the replacement is
measured. Starting it inside this round would leave a half-ported flow-control
implementation in the tree, and `SKILL.md` is explicit that an unfinished tree is
worse than one never started.

There is no smaller fix worth having. Memory cannot be bounded without either
throttling the producer or failing the call; round 208 chose the second because
the first was implemented by not reading, which killed the connection. B-15
restores the first by a mechanism that never stops reading. A "refuse only if
the consumer has made no progress for N seconds" variant was considered and
rejected on the spot: it would let a slow consumer's backlog grow without bound,
which is the hole round 208 exists to close.

What this round adds to B-15 is the number that sizes it, and P-05 as its
acceptance test — currently red, and it must read "completed, consumed 3000"
when B-15 lands.

## Links

Lead `../backlog/B-15-rpc-level-grants-on-http2.md` — sharpened with this
measurement; its urgency is no longer a matter of taste.
Bench `../probes/P-05-slow-consumer-is-throttled.md` — new, validated by its
control, deliberately left red.
Round `208-refuse-instead-of-pausing.md` — whose trade this re-measures.
Lead `../backlog/B-12-http2-cancel-kills-the-connection.md` — the decision trail.
