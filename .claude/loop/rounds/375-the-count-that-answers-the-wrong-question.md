---
round: 375
verdict: FIXED
packages: [rpc_dart]
lens: RPC-23
bench: P-60 — reused
commit: yes
---

# Round 375 — the count that answers the wrong question

## Target

The owner asked to settle B-50, and attached consumer evidence to it: rhyolite
has moved the blob upload this record was written about **off client-stream and
onto bidirectional**, acknowledging each blob on the response stream as it is
durably written.

That evidence lands on round 369's ANALYSIS and refutes round 369's proposed
FIX, which is the more useful outcome of the two.

RPC-23: prose that names a mechanism which does not exist. Two pieces of it
here, and rule one makes the divergence the defect.

## Hypothesis

`x-rpc-requests-consumed` in the trailer — 369's proposal — is the right fix.

It is not. **It answers the wrong question.** A count at the end says how many
messages the library HANDED the handler; resumption needs to know WHICH pieces
are durable, and a handler can be given 17, commit 3 and fail. 369 optimised
"tell a full read from a partial one", and the real question is "where do I
resume". The first does not yield the second, and the count also arrives after
the bytes rather than before them.

A per-message ack on a bidirectional response stream answers both, needs no wire
change, and is what the consumer actually shipped.

## Before

Two divergences between prose and code, both measured.

**1. `droppedRequests` documents a reader that does not exist:**

> Zero on every healthy call. The pipeline reads it when the call ends, so a
> handler that was fed less than the peer sent cannot finish quietly.

`grep` over the workspace: one declaration, two increments, **zero readers**.
Four paths driven at it across two rounds, none arriving:

```
path                            round   DROPPED logged
shortRead  (break, answer now)   369          0
shortHold  (break, hold 400ms)   369          0
short      (break, hold 600ms)   375          0
neverReads (never subscribes)    375          0
```

Reading the code for why: `pushRequest` is only reached when the sink is
non-null, so its increment needs `sink.isClosed` — a peer that keeps sending
after its own half-close, which is a protocol violation. The other increment
needs `detachRequestSink`, which fires from the controller's `onCancel` and did
not on any measured path.

**2. `addClientStreamMethod` says nothing about the behaviour B-50 measured.**
P-60, reused unchanged: 17 sent, 3 given to the handler, caller told `OK`,
against a `fullRead` control of 17/17/OK — byte-identical from the caller — and
a `throws` control proving a non-OK ending is readable on that path.

## Mechanism

The early answer itself is correct: gRPC allows a server to respond without
draining, and during an upload it is useful. What is wrong is that the caller
cannot tell the two apart, and that nothing in the API says so — so the next
caller builds a resumable transfer on a shape that cannot report what landed.

## After

```
claim                                        before   after
droppedRequests: "the pipeline reads it"     0 readers, asserted true   corrected
paths measured at that increment             4 tried, 0 arrived         stated
addClientStreamMethod: partial read named    no                         yes, with 17/3/OK
```

Both comments now describe what the code does.

`droppedRequests` says it is diagnostic only, that nothing reads it, that it does
not fail the call, and what is still reachable (a peer sending past its own
half-close).

`addClientStreamMethod` states the measured behaviour with its numbers, says the
early answer is deliberate, and routes a resumable transfer to
`addBidirectionalMethod` with a per-message ack — naming the reason the library
cannot do better: it knows what it HANDED OVER, never what was COMMITTED.

## Canary

n/a — the change is prose, and a doc comment has no runtime to switch off.

The evidence is the four measurements above plus P-60's two controls, all of
which vary something and change the outcome: `fullRead` differs from `shortRead`
by one line of handler code and reports the same thing to the caller; `throws`
differs again and reports something else, so the OKs are real.

`melos run analyze` and `format:check` are the only mechanical checks a comment
has, and both are green.

## Gate

`fvm dart analyze lib` clean, `fvm dart format` clean, `fvm dart test -j 8`
**+1541 ~1**. Workspace gate unchanged from round 374, which passed all four;
no executable line moved in this round.

## Not fixed

**The honesty problem itself, and this is now a decision rather than a gap.**
A client-stream caller still cannot tell a full read from a partial one. The
trailer count is rejected — not on cost, but because it answers the wrong
question — and no cheaper mechanism exists: the caller knows what it sent, only
the peer knows what was read, and closing that gap means changing the wire.

What the round delivers instead is that nobody arrives there by accident: the
API now says the shape cannot report it and points at the one that can.

**B-50 closes on that basis**, with the consumer evidence recorded as what
decided it.

## Links

- RPC-23 — the lens; `applied:` gains 375
- B-50 — closed by this round
- P-60 — reused unchanged; its controls are this round's evidence
- Round 369 — filed B-50 and proposed the fix this round rejects
- Round 373 — fixed the bidi subscription the recommended shape depends on
