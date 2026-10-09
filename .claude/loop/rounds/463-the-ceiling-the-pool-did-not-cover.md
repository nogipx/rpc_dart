---
round: 463
verdict: FIXED
packages: [rpc_dart_http]
lens: RPC-05
bench: P-112 — new
commit: yes
severity: S2
---

# Round 463 — the ceiling the connection pool did not cover

## Target

B-75. The owner's decision is conditional and its step 1 is a measurement:
*"answer whether the limit is MEANINGFUL on the HTTP/1.1 caller … concurrency is
already bounded by the `HttpClient` connection pool, so the limit may be
meaningless rather than missing."* If meaningful, charge it where the siblings
do; if not, close it as a negative plus a doc line.

Read first, as the lead and the decision both require: RPC-05 (where a
concurrency limit is charged) and C-29 (what the limit is for).

**Scope: one transport, one charge point.** `maxActiveStreams` on the caller side
has three implementations and the third is an absence. The responder side is not
in scope — `rpc_http_responder_transport.dart:219` already enforces it, which
round 451 established and the lead's own table omits.

## Hypothesis

Two, and they contradict each other, which is why the round is a measurement
before it is a fix. Either the HTTP/1.1 caller's concurrency is already bounded
by the `HttpClient` connection pool — in which case the limit is redundant and
this closes as a negative — or nothing bounds it and a policy an operator set
does nothing on one transport out of three.

## Before

P-112 — twelve concurrent calls against a parked handler, ceiling 4 on the
caller, 1024 on the responder:

```
                    admitted  refused  peak handlers  peak server requests
core (channel)         4         8           4
http2                  4         8           4
HTTP/1.1              12         0          12                12
```

**The limit is meaningful and it was inert.** The pool hypothesis is refuted and
not marginally: all twelve requests were open at the server at once, because
`dart:io`'s `maxConnectionsPerHost` defaults to unlimited.

## The question the lead asked, answered by the library itself

Round 451 read C-29 — *"a peer pins roughly `maxActiveStreams x 33 KiB` per
connection"* — and concluded the limit may be a responder-side defence only, on
which reading http2's caller-side bound is the odd one out.

It is not, and the evidence is in http2's own comment at the charge point:

> *"Without it `maxActiveStreams` was inert on this transport, silently: a client
> configured with 5 opened 500 concurrent streams — 500 HTTP/2 streams, 500
> subscriptions, 500 stream controllers — with nothing refused and no error
> anywhere. The same configuration threw on the 6th call over every other
> transport."*

So the caller-side ceiling is a decision this library already took, twice, for a
measured reason, and HTTP/1.1 is the transport that never got it. That settles
the "what is it for" question without a new argument.

## Mechanism

`_activeStreams`, a `Set<int>` of ids minted and not yet given back, charged in
`createStream()` and released in `releaseStreamId()` — the same two points as
core, and the same `RESOURCE_EXHAUSTED` with the same wording as both siblings.

**Neither existing counter could serve.** `_pending` holds a call only between
`sendMetadata` and `finishSending`; `_inFlight` only after that. Each is empty
for part of every call's life, so a ceiling read off either admits past itself.

## After

```
HTTP/1.1               4         8           4                 4
refusal                status=8 Too many active streams: 4 (max: 4)
```

Identical to both siblings on every column.

## Enumerate the endings — and one of them turned out redundant

RPC-05: *"Charging is only half a lifecycle … enumerate the endings, not the
happy path."* Four, each run past the ceiling with the second release site
ABLATED:

```
                       ok   failed   activeStreams after
completion             12      0            0
connection refused      0     12            0
HTTP 503                0     12            0
200, text/html          0     12            0
sequential 12 at 4     12      0            0
```

Every ending reaches `releaseStreamId`, which the endpoint calls — so the removal
in `_fireRequest`'s `finally` is redundant TODAY. **It is kept anyway, and the
comment says both halves**: core prunes on a terminal inbound frame as well as in
`releaseStreamId`, http2 removes at four sites, and the behaviour being relied on
belongs to another layer. The failure if that layer ever changes is the worst one
this limit has — a ceiling that ratchets shut for good, N calls into a process.

Recording it because the alternative is a line nobody can tell from an oversight.

## Canary

**The ceiling removed** (`if (false && …)`) — the witness fails with exactly the
number the probe measured before the fix, and the CONTROL stays green, so it
isolates:

    a burst past the ceiling is refused, RESOURCE_EXHAUSTED
      Expected: <4>
        Actual: <12>

**The second release site removed** is the canary that did NOT fire, and that is
the finding above rather than a gap: `ok=12/12` and `activeStreams=0` on all four
endings. A canary that cannot kill a line is evidence about the line.

## Gate

`melos run analyze` SUCCESS, `format:check` SUCCESS (after `format`),
`license:check` SUCCESS, `test:unit --no-select` SUCCESS across all 14 packages —
`rpc_dart_http` 147, `rpc_dart` 1681, `rpc_dart_http2` 247.

`the_caller_ceiling_applies_test.dart`: the burst witness, a high-ceiling CONTROL
proving the refusal is the ceiling and not the burst, and a sequential GUARD
against the ratchet.

`activeStreams` joins `health().details`, so the counter is observable from
outside — round 452's rule, that a divergence you cannot observe is an unbuilt
instrument.

## Not fixed

**The CHANGELOG line the decision asks for is deliberately not written.** Step 2
says to put the new refusals in the CHANGELOG. `rpc_dart_http`'s top section is
`## 0.4.0`, which is tagged `rpc_dart_http-0.4.0` and published — so the line
belongs to a version that does not exist yet, and creating one is a release
decision. The text, ready to paste under whatever the next version is:

> **`maxActiveStreams` now applies to the HTTP/1.1 CALLER.** It was read
> nowhere: a client configured with 4 opened 12 concurrent calls, all reaching
> the server at once, where core and HTTP/2 refused the 5th. Concurrency past the
> ceiling is now `RESOURCE_EXHAUSTED`, as on every other transport.

**Only the unary shape was driven.** The charge point is `createStream()`, which
every call shape goes through, so admission is covered by construction; the
ENDINGS differ per shape and only unary's were measured.

## Links

- RPC-05 — the charge point, and "enumerate the endings"; this is its first
  application where an ending turned out to have a redundant release rather than
  a missing one
- C-29 — read first, as the lead requires; it describes the RESPONDER scope, and
  round 451 over-read that into a claim about the caller side
- P-112 — the bench
- B-75 — closed
- Round 452 — expose the counter, or the divergence cannot be observed
