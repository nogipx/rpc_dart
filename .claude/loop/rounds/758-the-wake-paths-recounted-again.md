---
round: 758
verdict: CLEAN
packages: [rpc_dart]
lens: RPC-09
bench: P-10 — reused
commit: yes
release: none
---

# Round 758 — the wake paths recounted again

## Target

RPC-09, `swept here (round 743)`, which `next` lists as moved: 3 files since,
`client_connection.dart`, `retry_interceptor.dart` and `transport.dart`. Those
are rounds 750-751's reconnect wait, and round 751 applied this lens to it,
bounding the wait by the call's deadline. What the moved files did not cover
is the lens's own standing check: recount the wake paths from the code, and
re-run P-10 with its ablation. B-267 and B-270 not taken.

## Hypothesis

A wake path was lost or added since round 717, or a parked sender can now
hold its call past the response.

## Before

Every `_wake` / `wakeAll` call site in `flow_controller.dart`, by enclosing
method (dart-runner `find_callers`):

```
  _armLegacyGrace       the legacy grace timer
  _onGrant              per-stream credit
  handleInbound         connection credit
  _noteMessagesLegacy   seeded message credit
  forget                the call ending
  close
  six, the same six as round 717
```

P-10:

```
  CONTROL  handler drains            completed 0.2 s, 2000 pulled
  CASE     handler answers early     completed 0.4 s, 19 pulled, 0 consumed
```

## Mechanism

The caller's future resolves on the response path, independent of the
request pump, so a send parked at the window cannot hold an answered call.

## After

n/a — nothing changed.

## Canary

P-10's ablation, `_onGrant` refusing every grant:

```
  CONTROL  handler drains            HUNG, no answer in 20 s, 16 pulled
  CASE     handler answers early     completed 0.4 s
```

As in rounds 221, 322 and 434: the bench still sees a starved sender, and the
answered call still returns. Restored; `git status` clean.

## The verdict questions

1. Yes: the ablation removes only the per-stream credit path.
2. Yes: 0.2 s against HUNG at 20 s.
3. In the caller's own outcome and the handler's pull count.
4. The wake count was enumerated by `find_callers`, not read.
5. n/a, no fix; the ablation rows are quoted.
6. n/a.
7. CLEAN with a valid control.
8. The three moved files were set aside on round 751's measurement of the
   same wait under this lens, not on its text alone: the wait's bound is the
   call's deadline (P-255). B-267 and B-270 left open.
9. None.
A1. n/a.
A2. Volume: 8000 KiB against a 64 KiB window.
L1. n/a: no refusal; the starved row is a hang.

## Gate

n/a — no code change; `lib/` restored after the ablation.

## Not fixed

Nothing.

## Links

Lens `../lenses/RPC-09-deadline-below-write.md` — `applied: [..., 758]`,
`swept here (round 758, a0a78cac)`.
Bench `../probes/P-10-parked-sender-learns.md` — reused.
Round 751 and `../probes/P-255-a-reconnect-wait-against-the-call.md`.
