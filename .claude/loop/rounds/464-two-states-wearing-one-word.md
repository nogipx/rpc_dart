---
round: 464
verdict: FIXED
packages: [rpc_dart, rpc_dart_websocket, rpc_dart_http2]
lens: RPC-25
bench: P-113 — new
commit: yes
---

# Round 464 — two states wearing one word

## Target

B-76 step 2. Step 1 is REFUTED and must not be carried out — round 449 measured
the silent drop and it is not there (C-48). What survives is the owner's second
instruction and the question attached to it: *"make the three machines ONE"*,
with the `## Ask` answered before any code — **if the three were one, whose
behaviour would the shared version have, and which of the three does that
CHANGE?**

Scope: the disconnected refusal on all three caller-side machines — the websocket
transport, the http2 transport, and `_ReconnectingTransportProxy`. The id-reuse
half of the lead is NOT in scope and stays open in the body of B-76.

## Hypothesis

The Ask has no answer as posed, because the three machines are not answering one
question. The bench is built to show that rather than to pick a winner.

## Before

P-113 — two arms per machine, which is the whole design. A send 200 ms into an
800 ms factory stall, and a send after a reconnect whose factory threw:

```
                          websocket   http2     health
during the factory await     9          14      degraded
after a FAILED reconnect     9           9      unhealthy
```

The lead's finding — one cell of disagreement — is there. The finding the lead
does not have is the other axis: **both machines give ONE status to TWO states**,
and `health()` already tells them apart.

## The Ask, answered

**Neither machine's behaviour, because the question has two answers.**

- A reconnect IN FLIGHT will have a connection in tens of milliseconds and the
  caller can do nothing but wait. That is what UNAVAILABLE is for.
- A reconnect that FAILED, or was never started, needs `reconnect()` called.
  That is FAILED_PRECONDITION, whose meaning is "do not retry until the state is
  fixed".

Which copies does that CHANGE? The websocket's in-flight cell (9 -> 14), the
proxy's (same), and http2's TYPE though not its code.

## The sentence the old answer rested on, re-measured

The websocket's choice is a prior round's deliberate decision, written into the
matcher that pins it:

> *"a synthetic UNAVAILABLE is RETRYABLE and invites the caller to repeat what
> cannot work"*

L-13: re-measure the sentence, do not override it. It has a hidden premise —
that "repeat" means "repeat immediately" — and `RpcRetryInterceptor` backs off.
P-114, one call through a retry interceptor fired 100 ms into an 800 ms window,
first backoff 250 ms:

```
control, no reconnect                     OK pong after 30ms
FAILED_PRECONDITION (what was shipped)    status=9 after 0ms
UNAVAILABLE (this round)                  OK pong after 711ms
```

**The sentence is false for this state.** `after 0ms` is the cost: the call was
never retried and failed outright for a condition that cleared 700 ms later.

## Mechanism

`RpcNoConnectionException` in core, beside `RpcClosedException` and for the same
reason RPC-25 gave when that type was introduced: the fact was being re-derived
by each site. It takes `reconnecting` and picks the status from it, so there is
one place that knows which advice goes with which state, and callers can branch
on `e.reconnecting` instead of on a message.

All three machines throw it, and **none of them keeps a new flag for
"reconnecting"**:

```
websocket   _reconnecting != null       the single-flight future, already there
http2       _reconnecting != null       the same field, same name
the proxy   isReconnecting()            reads _connectingGuard, via a callback
```

That is the load-bearing part of the shape. A fresh bool would have needed
clearing at three exits in the websocket's `reconnect`, three in http2's, and
SEVEN in the proxy's connect loop — and an unclear bool leaves a caller retrying
into a loop that gave up. Every one of the three already had a field that means
"an attempt is in flight" and is cleared in exactly one place.

One more change on http2: `_disconnected = true` before the factory await. Not
the silent-drop fix round 449 refuted — nothing is lost in that window either
way, which 449 measured. It makes `_ensureUsable` the code that ANSWERS, instead
of the refusal coming from the discarded connection: the right status by accident
and the wrong type.

## After

```
                          websocket                          http2
during the factory await  RpcNoConnectionException code=14   same
after a FAILED reconnect  RpcNoConnectionException code=9    same
```

## Canary

**The status split removed** — `RpcNoConnectionException` always
FAILED_PRECONDITION, which is exactly what shipped before this round. P-114 goes
from `OK pong after 711ms` back to `status=9 after 0ms`: the retried call is lost
again. One line in core, and it reaches the behaviour through two packages.

The type half has its own witness rather than a canary:
`a_failed_reconnect_is_not_a_running_one_test.dart` asserts the `(status,
reconnecting)` PAIR, so a regression to one answer for both states fails on the
arm that did not change as well as on the one that did.

## The test that had to be rewritten, not made green

`calls_during_reconnect_are_refused_test.dart` demanded FAILED_PRECONDITION and
said why in its matcher's doc. **Its numbers are now in that doc**, with the
sentence marked false and the reason: a retry is not a repeat. The matcher also
gained a `reconnecting` assertion, so it pins the new fact rather than merely
tolerating it.

This is the round's own trap avoided: the fastest way to green was to change
`failedPrecondition` to `unavailable` in a matcher and move on, which is how a
measured decision becomes an unexplained one.

## Gate

`melos run analyze` SUCCESS, `format:check` SUCCESS, `license:check` SUCCESS,
`test:unit --no-select` SUCCESS across all 14 packages — `rpc_dart_websocket`
187, `rpc_dart` 1681, `rpc_dart_http2` 247.

## Not fixed

**The id-reuse half of B-76 is untouched** and the lead stays open for it. Three
machines carry three mechanisms for the same problem — a `Set` of live ids, a
never-reset counter, an id watermark — and this round changed none of them.

**The proxy's arm was not benched.** Its `isReconnecting` reads
`_connectingGuard`, which is the same field the connect loop's own single-flight
check uses, and its refusal goes through the same core type; but the two-arm
table was measured on the two transports only, and driving
`RpcClientConnection`'s backoff loop to a deliberate failure is a bench this
round did not build.

## Links

- RPC-25 — three implementations of one duty; here the divergence was not what
  they DO but what they TELL a caller, which is round 449's surviving finding
- L-13 — the decision inherits the sentence it was taken on, and the sentence was
  measurable
- P-113 — the table; P-114 — the sentence
- B-76 — step 2 closed, step 1 refuted by round 449, the id-reuse half still open
- C-48 — why step 1 must not be carried out
