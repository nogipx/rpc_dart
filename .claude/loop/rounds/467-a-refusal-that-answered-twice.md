---
round: 467
verdict: FIXED
packages: [rpc_dart]
lens: RPC-05
bench: P-106 — reused
commit: yes
severity: S2
---

# Round 467 — a refusal that answered twice

## Target

B-90, filed by round 454's own GUARD arm and never decided by the owner — which
makes it mine to take from the state. Its `## Owner decision` is empty because it
was filed after the backlog review, not because it is waiting on one.

**Scope, counted before the fix.** The lead names one refusal and asks the class
be counted first (L-12). `grep -n _sendGrpcErrorAndCleanup` returns **16 call
sites**, and the lead's second question — *"does it leave the id anywhere?"* —
turns out to be the whole answer: it does, in `_cleanupStream`, in its `finally`.
So the class is not "which refusals forget the id" but "every refusal that runs
this helper detached", which is all sixteen. One mechanism, one site.

## Hypothesis

The double answer is not a missing remember, it is a LATE one. Every refusal site
calls the helper through `_detached`, so the id is recorded a microtask after the
next inbound frame has already been routed.

## Before

P-106 reused, with one new arm for the sibling refusal the lead asked to be
driven. A call opened as a peer opens one — metadata, then payload — is two
frames:

```
GUARD draining, NEW stream            [status=14, status=14]
CEILING at 1, a 2nd call (2 frames)   [status=8,  status=8]
```

**Both refusals, not one.** Two terminal statuses on one stream, which is a
protocol violation anywhere the peer keeps stream state.

The ceiling arm needed the client and responder to hold SEPARATE policies:
`RpcChannelTransport.pair(policy:)` gives both sides the ceiling, and since round
463 the caller's own `createStream` refuses first — so a shared policy measures
the client and reports it as the server. C-29's test note, arriving four rounds
after the round that made it matter on every transport.

## Mechanism

`_rememberClosedStream(streamId)` at the top of `_sendGrpcErrorAndCleanup`,
before its first `await`.

That is the whole fix, and the position is the point: an `async` body runs
synchronously up to the first await, so the id is recorded while the call site is
still on the stack — before `_detached` has returned, and therefore before the
next frame can be routed. The `finally` still cleans up; what changes is that the
one fact the next frame needs no longer waits for it.

**One site, not sixteen.** The race is in none of the call sites: it is in the gap
between deciding to refuse and recording that the id is done.

## After

```
GUARD draining, NEW stream            [status=14]
CEILING at 1, a 2nd call (2 frames)   [status=8]
```

## Canary

The line commented out, which is exactly the shipped behaviour:

    a drain refusal answers ONCE for a two-frame call
      Expected: ['14']
        Actual: ['14', '14']
    a ceiling refusal answers ONCE for a two-frame call
      Expected: ['8']
        Actual: ['8', '8']

Both witnesses, one line. The two GUARDs stay green under it, which is what says
the canary isolates the count rather than the refusal.

## Gate

`melos run analyze` SUCCESS, `format:check` SUCCESS, `license:check` SUCCESS,
`test:unit --no-select` SUCCESS across all 14 packages — `rpc_dart` 1685 (four
new), `rpc_dart_http2` 247, `rpc_dart_websocket` 187.

`a_refusal_answers_once_test.dart` asserts the LIST, never `contains`: the lead's
own warning is that `[14]` and `[14, 14]` read the same to a containment matcher,
which is how this survived. Two guards beside it — both refusals must still
refuse (answering zero would pass a "not twice" test), and a healthy call still
gets exactly one answer, and it is the handler's.

## Not fixed

**The lead's third question is unanswered**: what a peer does with the second
status. On a channel transport the caller may have released the id, so the second
refusal could land on a REUSED stream — RPC-03's territory, and it would make this
worse than noise. It is moot now on the paths measured here, and it is not moot
for any refusal this round did not drive.

**Fourteen of the sixteen sites were not driven.** They are covered by
construction — the fix is in the helper they all call, not in any of them — but
"covered by construction" is a reading, and only the drain and ceiling refusals
have a number.

## Links

- RPC-05 — a limit's refusal is part of its lifecycle; this is the refusal
  answering twice rather than a slot leaking
- L-12 — count the class first; here the count (16) is what made the fix one line
  instead of two
- Round 454 — filed this from its own GUARD arm, and fixed the same damage class
  by a different mechanism (ordering). "Count the answers, not just their
  presence" is its lesson, applied
- P-106, B-90
