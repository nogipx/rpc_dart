---
round: 434
verdict: CLEAN
packages: [rpc_dart]
lens: RPC-09
bench: P-10 — reused
commit: yes
---

# Round 434 — the fifth wake nobody counted

## Target

**RPC-09, re-swept** — the other lens `next` lists as swept-but-moved, at 57
files since round 322. Taken straight after RPC-14 for the same reason: a lens
that records what to compare against is cheap to re-run, and both had gone over
a hundred rounds.

RPC-09 records two things to redo, and is explicit that one of them must not be
copied:

> **The wake-path COUNT is part of the detector, and it must be recounted from
> the code.** 244 reported three ... and there are four ... A sweep that reports
> the previous sweep's number carries an undercount forward for as long as it is
> repeated.

## Hypothesis

The independence claim holds — a parked sender cannot delay an answer — and the
wake count is wrong again. The lens has already been wrong about it once, and
the mechanism has been restructured since 322.

## Before

**The count is FIVE, and the fifth has never been counted by any sweep.**

```
             round 244   round 322   round 434
wake paths       3           4           5
```

Recounted from the code, not from the record. Every call site of `_wake` /
`wakeAll` in `flow_controller.dart`, with the method each sits in:

```
:291  the legacy grace timer expiring          counted since 244
:378  _onGrant           per-STREAM credit     counted since 244
:537  handleInbound      CONNECTION credit     NEVER COUNTED
:593  forget             the call ending       added by 322
:606  close                                    counted since 244
```

`:537` is a genuinely separate path, not a second view of `:378`: connection
credit is shared and per-stream credit is not, so the two arrive on different
headers and neither implies the other. It has been there since connection-level
flow control existed; no sweep has ever listed it.

**The mechanism also MOVED**, which is why a grep for the lens's own names now
returns only http2. Core's parking left `channel_transport.dart` for a dedicated
`RpcFlowController` (`src/rpc/transports/flow_controller.dart`), and
`_fcAwaitCredit` / `_fcOnGrant` / `_fcForget` are now `awaitCredit` / `_onGrant`
/ `forget` on that class.

## Mechanism

n/a — the lens's shape does not arise. What moved is where the code lives and
how many ways a parked sender can be woken.

## After

P-10 reused, both columns, all eight cells:

```
                          normal              grants refused
  CONTROL drains     completed 'drained'   HUNG, 20 s, 16 pulled
                     0.2 s, 2000 pulled
  CASE    answers    completed 'early'     completed 'early'
          early      0.4 s, 19 pulled      0.4 s, 18 pulled
```

Against 221's table: identical except the pull counts on the CASE row, 19/18
where it recorded 17/16. That is the overdraft, which the bench's own text calls
"one window plus the overdraft" rather than a fixed number — same shape, not a
regression.

## Canary

The bench's own ablation, repeated because the code moved: `_onGrant` made to
refuse every grant.

**It still starves the sender, and that was not a given.** With a second,
uncounted wake path now known to exist, an ablation aimed only at the per-stream
grant could have left the connection-level grant waking the sender anyway — in
which case the control column would no longer hang and P-10 would be `broken`
rather than `valid`. It hangs: 20 s, 16 pulled. The sender parks on per-stream
credit, and connection credit alone does not admit a message.

## Gate

```
melos run analyze          SUCCESS, 21 packages + rpc_dart_wasm
rpc_dart test/transports   SUCCESS
```

The only code edit was the ablation, reverted; the tree is byte-identical to
round 432's, which the full gate covered.

## Not fixed

**The fifth wake is counted, not witnessed.** Nothing shows that the
connection-level grant's wake is load-bearing — an ablation aimed at `:537`
alone was not run, and the answer might well be that per-stream credit already
covers every case the bench reaches. That is a sweep for whoever next needs it,
and it is now written down rather than latent.

**B-13 is untouched**, as in 210 and 322: a parked sender outliving its own call
is a leaked completer rather than a hang, so it is outside this lens.

## Links

- RPC-09 — re-swept; status moves to `swept here (round 434, 7ee3e602)`, and
  the count corrected to five with the moved file names recorded
- P-10 — reused, ablation repeated, all eight cells hold; stays `valid`
- round 322 — the sweep this compares against, and the one that corrected the
  count from three to four
- B-13 — still out of scope, still for the same reason
