---
round: 774
verdict: CLEAN
packages: [rpc_dart]
lens: RPC-09
bench: P-10 — reused
commit: yes
release: none
---

# Round 774 — the wake paths after the grant change

## Target

RPC-09, swept in round 758; `next` lists 4 files moved under it since,
among them `flow_controller.dart`, where round 768 moved the grant cap from
the increment to the result in both `_onByteGrant` and the connection
grant. A grant is the wake path a parked sender relies on.

## Hypothesis

The answer path still does not wait on a parked send, and the bench still
sees a credit hang when the stream grant path is starved.

## Before

P-10 (`parked_sender_learns.dart`), both columns:

```
                          normal                   grants refused
  CONTROL drains     completed 'drained'       HUNG, 20.0 s, 16 pulled
                     2000 pulled
  CASE answers       completed 'early'         completed 'early'
  early              0.4 s, 19 pulled          0.4 s, 19 pulled
```

The ablation removed `_onByteGrant` from `_onGrant`, restored after.

## Mechanism

Unchanged: the answer path is independent of the send path, and the
connection grant alone does not admit a message parked on stream credit.

## After

n/a.

## Canary

n/a; the ablated column is the control.

## The verdict questions

1. The columns differ in the stream grant path only.
2. Yes: HUNG against completed.
3. At the caller.
4. 20 s against 0.4 s.
5. n/a.
6. n/a.
7. CLEAN: all eight cells as in rounds 434 and 717.
8. Nothing dismissed.
9. None.
A1. One policy.
A2. Volume.
L1. n/a.

## Gate

n/a — no code change.

## Not fixed

Nothing.

## Links

Bench `../probes/P-10-parked-sender-learns.md`.
Round `768-a-message-larger-than-the-window-stalled-the-stream.md`.
