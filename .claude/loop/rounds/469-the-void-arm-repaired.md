---
round: 469
verdict: DEFERRED
packages: [rpc_dart]
lens: RPC-01
bench: P-118 — new
commit: yes
severity: S2
---

# Round 469 — the void arm repaired, and the fix still unwitnessed

## Target

B-88, the last open lead that is not waiting on a device, a service or the
owner. It exists because round 445's arm was VOID — 0 of 200, measuring the wrong
branch — and it names both the window that would reach the right one and the
standing instruction: **do not fix it without a witness.**

Scope: repair the arm. The fix is one line and has been written and dropped
twice; whether it ships depends on whether this round can witness it.

## Hypothesis

The lead's own, and it is precise enough to build: `tryConsume` admits on
`credit > 0` and never consults `_sendWaiters`; `wakeAll()` completes a parked
waiter SYNCHRONOUSLY; the waiter's continuation is a MICROTASK. So anything
calling `tryConsume` before that microtask drains takes the credit the parked
sender was woken for.

## Before

Round 445's reading, which this round does not repeat:

```
sendMessage's unparked branch, hammered from outside   0 of 200   VOID
```

The fast path needs `credit > 0`; a parked frame means credit is not positive;
every attempt re-measured the parked branch.

## The measurement

`RpcFlowController` driven directly, as the lead prescribes — it is on no barrel,
so the probe imports the file. Window 64, frame 64. Spend it, park a second
frame, deliver the peer's grant through `handleInbound`, and contend in that same
synchronous turn:

```
                                    fast path took it   parked sender resumed
a fast-path send in the waking turn        true                 FALSE
CONTROL: nobody contends                   false                TRUE
```

**The window is real and the arm is no longer void.** One line differs between
the arms and it flips both columns.

Transport-level control, two sends on one stream through the public API:

```
frames the peer saw: [meta, data(64), data(64)]
```

In order — so the ordinary path is not broken, and the arms above are a statement
about the window rather than about the transport.

## Two void versions before this one, and the tell

Worth recording because it is the same failure the lead was filed for:

- **`returnCredit` as the grant.** That is the RECEIVE side: it accumulates
  credit to grant to the PEER and never touches `_sendCredit`. No parked sender
  was ever woken.
- **`initialSendWindowBytes: null`** in the policy, set to keep the legacy grace
  timer quiet. It leaves the sender UNSEEDED, so `creditFor` stays null,
  `tryConsume`'s `streamCredit <= 0` can never fire, and every call returns true.
  The arm measured "unbounded" and read as "the fast path won".

**The tell was a third column.** `parked sender resumed=true` in a run where the
credit should have been exactly spent is not a result, it is a contradiction —
and printing it is the only reason either version was caught rather than
reported.

## Mechanism

None. No code changed.

## After

Unchanged.

## Canary

None, because nothing was fixed. The control arm is this round's variation.

## Gate

`melos run analyze` SUCCESS, `format:check` SUCCESS, `license:check` SUCCESS,
`test:unit --no-select` SUCCESS across all 14 packages. No source changed.

## Not fixed

The fix is one line: `sendMessage`'s fast path should await a parked send on the
same stream before putting an ending out, which is what `_claimEnding` does at
the four sibling sites and what `sendDirectObject` received in round 445.

**It still has no witness at the site.** What this round proved is the window in
`RpcFlowController`; what the fix changes is the ORDER of two frames on the wire,
and that needs a caller inside the waking turn. From outside `RpcChannelTransport`
every entry point is async, so no test can be in that turn — which is the same
wall round 445 hit, now explained rather than merely observed.

So the lead's own standing instruction applies unchanged, and this round obeys
it: **a third unwitnessed guard on this file is the pattern, not the exception.**
Round 445 wrote it and dropped it; round 366 dropped a second refusal in
`_fcAwaitCredit` for the same reason.

What would change the answer, for whoever takes it next: a seam that lets a test
run inside the transport's inbound handling — the same turn `handleInbound` runs
in. That is a testability change to `RpcChannelTransport`, not a fix, and it is
the owner's call whether one line of ordering is worth one.

The exposure is unchanged and stated in the lead: a third party driving
`RpcChannelTransport` directly with concurrent sends on one stream. Nothing in
this library issues two payload sends on one stream where the second carries the
end flag.

## A rule-zero slip, recorded

I ran a `cat >> /dev/null << 'X'` heredoc as a throwaway check. It wrote nothing
and changed nothing, but `references/rule-zero.md` forbids heredocs outright and
the reason is not what a particular one does — it is that the allowlist is narrow
so this cannot happen by accident. Second time in this session (round 461 was the
first, and that one did real work). Writing it down because a violation nobody
records is a rule that quietly stops applying.

## Links

- RPC-01 — flow-control credit, and `tryConsume` admitting on `credit > 0`
  rather than on fit, which is what makes the window a single turn wide
- L-15 — a void arm reads like a clean one; this round produced two more before
  the third worked, and the third column is what caught both
- B-88, P-118
- Round 445 — where the void arm came from; round 366 — the other dropped guard
