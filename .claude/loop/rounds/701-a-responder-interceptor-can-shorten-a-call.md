---
round: 701
verdict: FIXED
packages: [rpc_dart]
lens: RPC-14
bench: none — `packages/core/rpc_dart/test/endpoint/a_responder_interceptor_deadline_is_enforced_test.dart`
commit: yes
release: changelog
---

# Round 701 — a responder interceptor can shorten a call

## Target

B-244, decided by the owner (option 1, tighten only): a deadline a responder
interceptor hands `next` changed what the handler read and nothing else,
because the stream's deadline timer is armed from the inbound message before
any interceptor runs.

## Hypothesis

Round 659's measurement holds at HEAD: a 200 ms interceptor timeout, a handler
that waits up to 2 s on its token, no client deadline -- the caller gets the
handler's late answer.

## Before

```
an earlier interceptor deadline ends the call   Expected: 'status 4'  Actual: 'late'   (about 2 s)
a later one does not extend the caller's        green
```

## Mechanism

As the lead read it: `state.armDeadline` runs once, in the context built from
the inbound message.

## Fix

- The base endpoint's four interceptor chains call a private hook,
  `_handlerContextChosen(origin, ctx)`, with the context the handler will get
  (a no-op in the base).
- The responder pipeline maps each call's starting token to its stream state
  (an `Expando`, so it holds nothing once the call is gone), records the armed
  deadline on the state (`deadlineAt`), and in the hook re-arms the timer only
  when the chosen deadline is EARLIER. A later one, or none, keeps the
  caller's. A call the endpoint MAKES has no entry, so on a peer the outgoing
  half is untouched.
- The core skill's deadline section says a responder interceptor may shorten
  the call and never extend it.

## After

2 of 2 green: the earlier deadline ends the call with DEADLINE_EXCEEDED, the
handler's token cancelled, under 1 s.

## Canary

The hook reading no deadline (`chosen = null`): `Actual: 'late'`, exactly
Before. Restored: green. (A first canary written as `origin == null || true`
did not compile -- it defeats type promotion -- and is not counted.)

## The verdict questions

1. Yes: one canary; the later-deadline test is the control.
2. Yes: the scenario round 659 measured.
3. Yes: the caller's status, the handler's token, the time.
4. Not zero-valued.
5. Yes, quoted.
6. One cause.
7. Yes; the owner's option 1.
8. None.

## Gate

`analyze`, `format:check`, `test:unit`, `check:skills`.

## Not fixed

Nothing in scope.

## Links

Lead `../backlog/B-244-a-responder-interceptors-deadline-is-not-enforced.md` closed.
Lens `../lenses/RPC-14-timeout-abandons-work.md` -- `applied: [..., 701]`.
