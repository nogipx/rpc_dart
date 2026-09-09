---
round: 210
verdict: CLEAN
packages: [rpc_dart, rpc_dart_http2]
lens: RPC-09
bench: none — two probes, neither promoted; see "Not fixed"
budget: probes 1/3, canaries 0/3
review: self — the session forbids the Agent tool unless the user asks, so the `loop.py review` prompt was answered in full against the record and both probes; approved 9 of 10, the "no" is Q4 and is recorded below
commit: no
---

# Round 210 — the answer does not wait on the send

## Target

Not the lens `next` named. RPC-01 has now been offered four rounds running
because its status is `confirmed` rather than `swept here`, and SKILL.md ranks a
NEVER-APPLIED lens above the rank. RPC-09 (`applied: []`) is a hang, in a
subsystem the last four rounds did not touch — and round 208 had just made the
http2 responder REFUSE a stalled upload, which is precisely the situation RPC-09
describes: a server that stops reading while the client is mid-send.

## Hypothesis

The client writes the request and waits for the reply in sequence, so a send
parked in the flow-control window can outlive an answer sitting unread in the
same stream. Round 208 would then have replaced an unbounded upload with a hang.

## Before

```
http2, a deaf handler, default 4 MiB window, the caller's own call future:

  CONTROL handler consumes  : completed 'done',  7.0 s, 40000 pulled, 40000 consumed
  CASE    server refuses    : RpcStatusException(8) "Request exceeds the
                              un-consumed window (4197354 > 4194304 bytes)",
                              0.2 s, 1038 pulled, 0 consumed

core channel transport, 64 KiB window, 8000 KiB offered:

  CONTROL handler drains    : completed 'drained', 0.2 s, 2000 pulled
  CASE    handler answers
          while the client
          is PARKED         : completed 'early',   0.4 s,   17 pulled, 0 consumed
```

Probes: `packages/transport/rpc_dart_http2/.dart_tool/probe/refusal_reaches_the_uploader.dart`
and `packages/core/rpc_dart/.dart_tool/probe/parked_sender_learns.dart`.

17 messages is 68 KiB against a 64 KiB window — the client is genuinely parked
in `_fcAwaitCredit` when the answer arrives, which is the state the lens is
about. 1038 messages is ~4.05 MiB, i.e. the http2 client stopped pulling its
generator the moment the refusal landed.

## Mechanism

The hypothesis does not hold, and the reason is worth recording: **the caller's
call future resolves on the RESPONSE path, which is independent of the request
pump.** An ablation removing `_fcWake` from `_fcForget` — the wake round 206
added so "a torn-down call can never leave a sender waiting forever" — did not
change either number: the case still completed in 0.4 s. So the answer never
waited on the send in the first place, and RPC-09's shape cannot arise here.

That ablation also caught the bench being wrong. The first cut had the handler
do `await requests.first`, which answered so fast that the client had pushed 3
messages against a 64 KiB window and never parked at all; ablating the wake
changed nothing because the probe was not exercising the path. Making the
handler consume nothing and simply wait 400 ms is what put the client at 17
messages and genuinely parked.

## After

n/a — nothing changed. `git diff` is empty; the ablation was reverted in place.

## Canary

n/a — no fix. The controls carry the claim: both rigs report a completion for a
draining handler, so a hang in the case would have been visible as the 20 s /
25 s timeout the probes already print as "HUNG".

## Gate

No code changed, so the gate is the one HEAD already passed at round 209.

## Not fixed

**Neither probe was promoted to a bench, deliberately.** `specs/probe.md` asks
that a control with the mechanism removed has SHOWN the bench can see the
defect, and that is exactly what failed here: the `_fcWake` ablation left both
numbers untouched. These rigs discriminate a draining handler from a
non-draining one; they have not been shown to discriminate a hang, so calling
them benches would overstate them.

What is genuinely unmeasured is the neighbouring question the ablation exposed:
an abandoned upload can leave a `sendMessage` future parked with nobody awaiting
it, and because the CALL completes regardless, nothing at this level would show
it. That is a leaked completer, not a hang — RPC-14 / U-17 territory, a
different observable. Filed as B-13.

Review Q4 ("if it is bounded, is it proven the mechanism could emit anything at
all?") is answered NO for the hang specifically, and that is why the verdict is
CLEAN-for-this-shape rather than a general negative: the probes prove the answer
arrives, not that a hang would have been caught.

## Links

Lesson `../lessons/L-03-no-backticks-in-a-shell-argument.md` — new, paid for by
this round's own commit.
Lens `../lenses/RPC-09-deadline-below-write.md` — `applied: [210]`,
`swept here (round 210, beed83e5)`, with the reason the shape cannot arise.
Lead `../backlog/B-13-parked-sender-outlives-its-call.md` — new, reason "bench".
Round `208-refuse-instead-of-pausing.md` — the refusal this checked.
