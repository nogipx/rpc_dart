---
round: 733
verdict: CLEAN
packages: [rpc_dart]
lens: RPC-05
bench: P-06 — reused
commit: yes
release: none
---

# Round 733 — an interceptor refusal returns its slot

## Target

RPC-05, last applied in round 520. It is the least recently taken of the
productive lenses. Since then, call endings have been added or reshaped: an
interceptor that shortens a call (round 701), refusals before the handler,
and the request-budget refusals of rounds 719-729. RPC-05 asks of each
ending whether `maxConcurrentHandlers` gets back what it charged at dispatch.

## Hypothesis

A responder interceptor that refuses without calling `next`, for a unary
call or a client-stream whose requests are never read, ends the call on a
path that does not release the handler slot.

## Before

P-06 (`handler_slots_return.dart`), extended with an interceptor that
refuses `denied*` methods (PERMISSION_DENIED) and two churn modes. The probe
churns six calls through one ending and then bursts twelve `park` calls
against a ceiling of three.

```
  churn mode            first churned call   peak, released   peak, ablated
  normal                ok                         3                0
  throw                 status 13                  3                0
  cancel                ok                         3                0
  deadline              status 4                   3                0
  interceptor-unary     status 7                   3                0
  interceptor-upload    status 7                   3                0
```

## Mechanism

The hypothesis does not hold. The slot is charged at dispatch and released
in `_withHandlerSlot`'s `finally`, which wraps the whole middleware,
interceptor and handler chain. An interceptor throwing before `next` leaves
through that same `finally`.

## After

n/a — nothing to fix.

## Canary

n/a — no fix. The ablation column is P-06's own control (`_releaseHandlerSlot`
made a no-op): 0 in every mode, the new ones included.

## The verdict questions

1. Yes: one ending per mode; the ablation differs by one early return.
2. Yes: 3 against 0.
3. Inside the handler, the only place that knows a handler runs.
4. The first-call column shows each new mode really reaches the refusal
   (status 7), not a pass-through (L-15).
5. No fix, so no witness.
6. n/a.
7. CLEAN.
8. None.
A1. One policy object, on the server pair.
A2. Neither.
L1. The refusal is the interceptor's own PERMISSION_DENIED.

## Gate

No library change. The ablation was reverted and `git status` showed only the
owner's `config.md`.

## Not fixed

Nothing found.

## Links

Lens `../lenses/RPC-05-concurrency-limit-charge-point.md` — `applied: [..., 733]`.
Bench `../probes/P-06-handler-slots-return.md` — two new modes.
