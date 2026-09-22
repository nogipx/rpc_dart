---
round: 433
verdict: CLEAN
packages: [rpc_dart, rpc_dart_isolate]
lens: RPC-14
bench: none — a grep sweep; the evidence is the detector's count against the one
  round 323 recorded, plus an ablation of the guard it canaried
commit: yes
---

# Round 433 — the count that did not move

## Target

**RPC-14, re-swept.** `loop.py next` has listed it under "SWEPT LENSES WHOSE
PATHS HAVE MOVED SINCE" for some time, at **57 files changed** since round
323's sweep, and the lens ends with an instruction addressed to exactly this
round:

> *"Round 323's count, for the next sweep to compare against: 7 in
> `rpc_dart/lib` ... and 4 sites in `rpc_dart_isolate`."*

A lens that records its own count is the cheapest re-sweep in the set, and it
had gone 110 rounds without one.

Chosen over another translation pass because a sweep answers a question and a
translation does not — and because three of this session's rounds have touched
these very paths, which is the risk a stale sweep exists to catch.

## Hypothesis

Either a new `.timeout(` has appeared that holds a handle, or the counts hold.
The specific worry: **round 430 changed the code inside `client_connection`'s
timeout region**, adding a `TypeError` catch around the factory await. That is
the one site this lens calls out as "adopts the abandoned attempt", so a change
there is the most likely way to have created an instance of the shape.

## Before

The detector, `grep -rn "\.timeout(" lib/`, against round 323's recorded count:

```
                         round 323   round 433
rpc_dart/lib                 7           7
rpc_dart_isolate/lib         4           4
```

Same eleven sites, every one shifted in line number by intervening edits — and
two of those edits are this session's: `client_connection.dart:514 -> :609`
(round 430) and `isolate_transport_web.dart:316 -> :124` (round 428 moved the
bridge out of that file).

Disposition, unchanged from 323:

```
2 hold something, deliberately   client_connection (adopts the abandoned
                                 attempt), call_scope (abandons a USER
                                 disposer by design and logs it)
5 wait on data                   ping, client/caller, unary/caller x2,
                                 base_endpoint's close()
4 isolate                        all four end in a teardown that kills the
                                 isolate and closes its ports
```

**The round-430 worry is answered and it is answered by one line.**
`_discardAbandonedAttempt` takes `Future<IRpcTransport>` and ends in
`.catchError((Object _) {})`, so the implicit downcast that round 430 made
possible is caught there rather than reaching the root zone. The adoption is
still safe.

## Mechanism

n/a — nothing is broken. What the round establishes is that the class still
does not arise, on a tree 57 files removed from the one that last said so.

## After

The three audit witnesses that pin this lens's guarantees all pass:

```
startup_failure_releases_the_isolate_test    a spawn that times out leaves no
                                             isolate and no ports behind
close_releases_the_isolate_test              5 tests, incl. 3 GUARDs
spawn_handshake_failure_test                 passes
```

## Canary

The sweep's claim is "every site is guarded", and a claim like that is worth
only what an ablation says. Round 323 canaried `teardownStartup()` on the ready
path; repeated here because the code has moved since:

```
teardownStartup() skipped     "a spawn that times out leaves no isolate and no
  (if (1 > 0) rethrow;)        ports behind" FAILED, at 20 s -- the child is
                               still running
```

Restored, and the package suite is green again. That is the control this CLEAN
verdict rests on: the detector finds sites, and at least one of the guards it
counts is watched by something that goes red when it is removed.

## Gate

```
melos run analyze        SUCCESS, 21 packages + rpc_dart_wasm
rpc_dart_isolate         SUCCESS, whole package
```

`test:unit`, `format:check` and `license:check` were run unchanged in round 432
and this round's only code edit was an ablation that has been reverted — the
tree is byte-identical to 432's, which the gate already covered.

## Not fixed

**"The class does not arise today" is still not "the class cannot arise."** The
lens's own `## What the sweep does NOT establish` stands: of the eleven sites,
one has a witness (the ready path, canaried above). The FIRST handshake path at
`isolate_transport.dart:424` is still unwitnessed, and its teardown is a strict
subset of the ready path's — which the lens correctly calls weaker than a
canary.

**The detector was not widened.** Round 233 used a broader one for websocket
(`.timeout( | Timer( | Timer. | Completer`) and found nothing, which is why that
package is not in this lens's paths. Widening the core detector is a different
sweep and would produce a count nothing can be compared against.

## Links

- RPC-14 — re-swept; status moves to `swept here (round 433, 7ee3e602)`
- round 323 — the sweep this one compares against, and the source of the count
- round 430 — the change that made this re-sweep worth doing first
- L-04 — a guard with no witness; ten of eleven sites are still that
