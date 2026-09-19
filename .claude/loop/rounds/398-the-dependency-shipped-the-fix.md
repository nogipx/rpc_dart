---
round: 398
verdict: FIXED
packages: [rpc_dart_http2]
lens: RPC-15
bench: P-73 — reused
commit: yes
---

# Round 398 — the dependency shipped the fix

## Target

B-53, open since round 384 and the longest-standing http2 lead: a client-side
RST_STREAM that races responses still in flight destroys the whole connection.
Rounds 385 and 387 ablated it down to the reset alone and placed the cause below
rpc_dart, inside `package:http2`. The lead's `reason:` said the way out needed
something the dependency does not expose.

The owner asked for `http2: ^3.1.0`. Its changelog's first line is *"Gracefully
handle receiving headers on a stream that the client has canceled (#1799)"* —
which is B-53's mechanism as round 387 described it: the SERVER writing a
response to a stream the client has just reset.

RPC-15: re-measure the loop's own record. The blocker was a statement about a
dependency, and dependencies ship.

## Hypothesis

B-53's blocker is a statement about someone else's code, and 3.1.0's changelog
describes the same race. Either the upgrade closes it, or the mechanism is not
the one the changelog names — and P-73 can tell the two apart, because its
racing arms die deterministically.

## The first measurement was invalid, and the owner caught it

The skipped witness is `request_sink_error_over_http2_test.dart`. Unskipped and
run on its own it passed — on 3.1.0 **and on 2.3.1**, twice each. Read as "the
upgrade did not do it", which was wrong in both directions.

B-53's own record says why, in the sentence that explains the skip: the fix of
round 384 *"narrows the window enough that the case is clean **run alone**, and
not enough under load: the http2 witness still failed inside the workspace
gate"*. Every one of those four runs was the arm that cannot see the defect.

The workspace gate then came back green on both versions too — so that witness
has gone quiet on 2.3.1 as well, and cannot settle anything either way.

> **A skipped test's reason line states the CONDITIONS under which it fails.**
> Reproducing its pass under other conditions measures nothing, and reads
> exactly like evidence. L-17.

> **The lead's frontmatter names its probe.** B-53 carries
> `probe: .../abort_kills_the_connection.dart` — P-73, deterministic, eight arms
> — and that is what should have been run first. The test was the artefact
> nearest to hand; the probe was the one built for this question.

## Before

P-73 reused unchanged, the only difference between runs being the resolved
http2 version:

```
arm                                 2.3.1         3.1.0
endpoint API, erroring requests     5 of 5 pong   5 of 5 pong
sinkErrors (echo)                   5 of 5 pong   5 of 5 pong
sinkErrors (silent)                 5 of 5 pong   5 of 5 pong
abort racing responses, awaited     5 of 5 DEAD   5 of 5 pong
abort racing responses, unawaited   5 of 5 DEAD   5 of 5 pong
abortWhileEmitting (30 ms settle)   5 of 5 pong   5 of 5 pong
abortWhenIdle                       5 of 5 pong   5 of 5 pong
halfClose (control)                 5 of 5 pong   5 of 5 pong
```

Ten of ten DEAD becomes ten of ten clean, and the six arms that were already
clean are untouched. `DEAD` is the whole connection: every later call on it
fails `RpcStatusException(14): HTTP/2 connection ... is no longer active`.

## Mechanism

Not ours. `abortWhileEmitting` differs from `abort racing responses` in one
thing — a 30 ms settle before the reset — and only the racing arms died, which
is round 387's result reproduced. The dependency now tolerates a response
written to a cancelled stream instead of treating it as a connection error.

## After

Nothing in rpc_dart changed. The floor is `http2: ^3.1.0`, and the two source
edits the upgrade forced are mechanical: `TransportConnection.terminate` gained
a `String? message` parameter in 3.0.0, so one test fake's override needed it.

Checked and not an issue here: 3.1.0's other BREAKING note adds a member to
`ClientTransportConnection`, an implementable class — nothing in this repository
implements it. 3.0.0 raises the SDK floor to 3.7.0; every package here already
requires 3.10.0.

## Canary

`abort_racing_responses_keeps_the_connection_test.dart`, derived from P-73's
racing arm, so the guard is a test rather than a probe nobody runs. On 2.3.1 it
fails — `['pong','pong','pong','DEAD(...)','DEAD(...)']` — and on 3.1.0 it
passes, with its three guard arms (settled abort, silent handler, half-close)
green on both.

**The race is the experiment.** The settled arm passes on both versions, so a
version of this test that waits before aborting witnesses nothing. That is said
in the file, because it is the mistake the round itself made first.

`request_sink_error_over_http2_test.dart` is unskipped, taking rpc_dart_http2
from `+225 ~1` to `+230` with no skips left.

## Gate

`melos run analyze` clean over 21 packages + wasm; `format:check` clean;
`license:check` compliant (1513 files); workspace suite **SUCCESS in all 14
packages**, rpc_dart_http2 **+230**, no skips.

## Not fixed

Nothing outstanding on B-53. The published `rpc_dart_http2` will need its
dependency floor and a version decision, which is the owner's — noted once and
not pursued.

## Links

- B-53 — closed here
- P-73 — reused unchanged; the version is the only variable
- RPC-15 — `applied:` gains 398; the blocker was a dependency's behaviour
- L-17 — a skipped test's reason line is a statement about conditions
