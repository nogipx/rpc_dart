---
round: 380 — where it was paid for
class: process
cost: a shipped default was one round away from being weakened fivefold. The owner decided B-47 on a sentence round 366 wrote — "the park buys nothing that can be named" — and 380 measured before carrying it out: the window bounds a burst 156.25 MiB -> 4.06 MiB, and the decided fix would have produced 19.95 MiB
paths: [—]
commit: 6a3cb2c1
status: active
---

# L-13 — a decision inherits the sentence it was taken on

An owner decision is evidence about what the owner WANTS. It is not evidence
about the code — it inherits whatever the round that framed the question got
right or wrong, and it launders a claim into an instruction along the way.

Round 366 wrote, in `## Not fixed`, that a parked sender "buys nothing that can
be named". That sentence became B-47, B-47 became a question, the question got
an answer, and the answer arrived at round 380 as a task: derive
`initialSendWindowBytes` from `maxMessageSize`. Nothing in that chain re-checked
the sentence, and by then it read as settled — it had an owner's decision on top
of it.

It was wrong. Measured over a real socket at 50 ms RTT:

```
policy                            frames      MiB
no initial window                  40000   156.25
64 KiB (shipped)                    1039     4.06
= maxMessageSize (16 MiB)           5108    19.95
```

Both halves of the contradiction were true of different things, which is how it
survived: for ONE message larger than the window the park really does buy
nothing, because the gate admits on `credit > 0` rather than on fit. Round 366
measured 2, 3 and 8 frames — it never ran a flood, which is the regime the field
exists for.

> **Before carrying out a decision, re-measure the sentence it was taken on.**
> Not the decision — the claim underneath it. The round that executes is the
> last point where a wrong premise is still cheap.

Two things made this one findable, and both are ordinary:

- **The field's own doc comment contradicted the claim, with numbers.** The
  standing rule is that a measured table inside a comment is somebody else's run
  rather than evidence — which is true, and which is not permission to ignore
  it. A contradiction between a comment and a round is a reason to measure, and
  here the comment was right to within 0.01 MiB.
- **The arm that would have been the fix was its own control.** Running it
  beside the others is what turned "this may be wrong" into "this makes it five
  times worse", and it cost one extra line in the probe.

Reported before acting rather than after, which is the only part of this that is
not luck: the verdict was RETRACTED and the owner's instruction was left
undone, with the numbers and the reason in the record.

## Round 464 — the sentence can be in a TEST's matcher, and it can be the ROUND's own

380's sentence was in a round record. 464's was in a matcher's doc comment, three
lines above the assertion it justifies:

> *"a synthetic UNAVAILABLE is RETRYABLE and invites the caller to repeat what
> cannot work"*

That is a decision, argued and written down, and the fastest way past it was to
change one identifier in the matcher and move on. Measured instead — one call
through `RpcRetryInterceptor` fired 100 ms into an 800 ms reconnect window:

```
FAILED_PRECONDITION   status=9 after 0ms     never retried
UNAVAILABLE           OK pong after 711ms    retried, succeeded
```

The sentence has a hidden premise — that "repeat" means "repeat immediately" —
and the library's own retry interceptor backs off, so the premise is false for
this state and true for the neighbouring one.

> **A test whose matcher carries an argument is a decision record, and changing
> the matcher is executing a decision.** Look for the sentence wherever the
> assertion is justified: a matcher, a `reason:`, a doc comment on a constant. A
> red test is the usual way you meet one, which is exactly when the temptation to
> edit it is highest.

> **When the sentence turns out false, rewrite the argument, not just the
> assertion.** The matcher now carries the two numbers and says which half of the
> old sentence survives. An assertion changed without its reason is worse than
> before: the next reader sees a bare choice where there used to be one with a
> defence.

Price here was one probe and the discipline to build it after the fix already
looked right — the change was written, the gate went red on exactly the test that
recorded the decision, and the measurement came second. Which is the one thing to
do differently: 380 measured BEFORE acting.

## Round 479 — the sentence can be RIGHT and still bound the measurement too tightly

380 and 464 both found a decision's sentence FALSE. 479 found one true, and
narrow, which is the harder version because nothing contradicts it.

B-71's decision closed with an item it called part of the round: *"a heartbeat
firing while a long call is in flight competes with it for the connection
window. Measure that before choosing the default interval."* Correct instinct,
one named axis — and that axis is clean. The ping sends only `sendMetadata`, and
only `sendMessage` consults flow-control credit, so a 120000 x 1 KiB stream runs
under the heartbeat with nothing disturbed.

The mechanism has more axes than the sentence named. `createStream()` throws
`resourceExhausted` at `maxActiveStreams`, and the round's own fix read every
throw as a dead peer:

```
against a LIVE responder          before fix              after
at the ceiling (4 of 4 ids)       CLOSED (false pos.)     open
CONTROL: one id free (3 of 4)     open                    open
under a 120000 x 1 KiB stream     open                    open
```

A heartbeat that closes a healthy connection at its concurrency ceiling kills
the very calls that filled it — worse than the silence the round set out to fix,
and it would have shipped had the measurement stopped where the sentence
pointed.

> **An open item names a RISK, not a measurement.** Measure the mechanism the
> item is worried about, across every axis it touches, and report which axis the
> sentence named. "Measure X before deciding Y" is a pointer to where the author
> smelled something, not the boundary of the work — and when X comes back clean,
> that is the moment to ask what ELSE is in contact, because a clean result on
> the named axis is exactly what closes the question prematurely.

Cheap, as it turned out: reading the two send paths before building any arm is
what moved the question, and the extra arm cost one function. The generalisable
half is what the fix became — **only SILENCE is death**: a probe that could not
be SENT, and a probe the peer ANSWERED with an error, are evidence the prober is
confused, not that the subject is gone. That shape is not specific to this
repository or this language; it is the standing failure of every health check
that reports its own resource exhaustion as the subject's death.

What a reader gives up by this being here rather than its own entry: L-13 is now
three rounds long and the first two are about a FALSE sentence, so the third
reads as an exception rather than as a rule of its own. Kept together anyway —
splitting it would put two entries in the index where one question belongs, and
the question is the same one: what standing does a decision's wording have over
the work.

See also [L-05](L-05-green-locally-is-not-green-clean.md) — an ablation proves
sensitivity, not portability. Same family: a result is about exactly what was
varied, and a sentence generalising it is a separate claim.
