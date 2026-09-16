---
round: 367
verdict: CLEAN
packages: [rpc_dart, rpc_dart_http2]
lens: RPC-25
bench: none — the instrument is an ablation over the existing suites, one per copy; no probe file can answer "which copy do the tests reach"
commit: yes
---

# Round 367 — the flow-control copies are all watched

## Target

The owner asked to refactor flow control, naming two steps: un-fuse the credit
accounting from the buffer bound inside `RpcChannelTransport`, then extract an
`RpcFlowController`.

RPC-25 is the only lens that can justify a refactor, and its bar is not line
count — it is **drift**, or, since round 331, **unequal coverage**. So the round
took the question the lens asks rather than the change the request named: are
these copies divergent, and are they unequally watched? The answer decides
whether the extraction is a defect repair or a preference.

Scope, counted before measuring (L-12): **three** copies of flow-control
accounting exist, not two — `RpcChannelTransport` (core, credit and grants),
`RpcHttp2ResponderTransport` and `RpcHttp2CallerTransport` (un-consumed budget,
refuse past it). All three were swept. This is a partial sweep of RPC-25's
`paths:`, scoped to the flow-control surface, so the lens does NOT get
`swept here`.

## Hypothesis

The two http2 copies are the same mechanism written twice and have drifted, or
one of the three copies is unwatched — either would make the extraction a repair
rather than a tidy-up.

## Before

Detector step 1 — fields every sibling declares: `_fcWindow`, `_fcOutstanding`,
`_fcRefused`, `_fcDischarge`, `_fcOnDelivered`, `_fcMetered`, `_fcForget`, all
in both http2 transports.

Detector step 3 — diffed by behaviour. Every difference is a deliberate
specialisation, and each is reachable only on its own side:

```
_fcOnDelivered gate    responder also admits _fcDeferred   caller has no defer path
refusal action         trailer + synthesized cancel        stream error + RST_STREAM
_fcForget sites        teardown only                       teardown AND end-of-stream
close() clears         _fcDeferred, _fcOutstanding         neither
```

The last row is real drift — three copies, three answers to "what does a close
clear". It is not a defect: after `close()` the transport is refused by its own
`isClosed` guard and the maps die with the object, and a reconnect builds a new
transport rather than reusing this one. Nothing reaches it (RPC-25 round 360 —
drift is a defect where something reaches it).

Detector, round-331 arm — ablate the same rule in each copy, count what the
suite catches:

```
copy                              baseline      ablated
http2 responder _fcOnDelivered    +218          +212 -6
http2 caller    _fcOnDelivered    +218          +217 -1
core _fcTryConsume                +1485 ~1      +1484 ~1 -1
```

Probe: none — each arm is one `Edit` in place (`if (1 > 0) return;`, and for the
core, the stream charge moved ahead of the connection gate), then the package's
own suite. The tree was restored between arms and `git diff --stat` verified
empty before the verdict.

## Mechanism

n/a — nothing is broken.

What the numbers say: no copy is at zero. Round 331's criterion is one copy
watched and one **not** (its own table read `-1` against `NOTHING CAUGHT IT`);
here it is 6, 1 and 1. Unequal in degree, not in kind. The extraction would
therefore inherit coverage it already has, and RPC-25's own rule applies — *what
a no-drift candidate earns: nothing.*

## After

n/a — no change made.

## Canary

n/a — no fix. The ablations above ARE the variation: all three went red where
the baseline was green, which is what makes the suite a valid instrument for the
question asked.

Failure messages, quoted because a timeout would not have counted:

    responder: 8.6 MiB reached the server for a handler consuming nothing
               Expected: a value less than <8388608>  Actual: <8992315>
    caller:    handler produced 20639 more items (80.6 MiB) while the client
               was paused; the peer window is not reaching it
    core:      TimeoutException after 0:00:30 — concurrent calls deadlocked
               on the pool

## Gate

All four green: `analyze`, `test:unit --no-select`, `format:check`,
`license:check`. Baselines taken this round and both green: `rpc_dart`
`+1485 ~1`, `rpc_dart_http2` `+218`.

**`analyze` was RED before this round touched anything**, and it is the lint the
config names by name:

    lib/src/rpc/streams/base_processor.dart:19:5
    Statements in an if should be enclosed in a block — curly_braces_in_flow_control_structures

Left by `2ec53853`, the commit C-38 records as having taken up the fix that
record says was reverted. Fixed here — one line, braces — for the reason
`config.md` gives beside the gate: *skipping this once shipped a `curly_braces`
lint into a published rpc_dart.* It is the only code this round changed, and it
is not this round's subject.

**`loop.py lint` was red too — 33 errors, all of them round 366's**, which
shipped its journal without running it: four records (`366`, `B-47`, `C-38`,
`P-58`) with no line in any index, off-schema frontmatter on those plus
`B-44`/`B-45`/`B-46`, and `RPC-01` not listing 366 in its `applied:`. Repaired
here rather than left, on round 366's own precedent — it found `format:check`
red from two earlier rounds of mine and formatted rather than reported. An
unindexed record is unreachable (L-09), which is the half that loses knowledge.
Now 0 errors.

Repairing C-38 turned up a rule-one divergence worth naming: it ends *"Reverted;
the transport is untouched"*, and `_refuseIfClosed` is in the transport today,
raising exactly the status C-38 specified for *"if it is ever taken up anyway"*.
The record described a tree that no longer exists; corrected in place, with its
measurement — which still stands — left alone.

## Not fixed

**The refactor itself — declined by the lens, not by cost.** Three copies, no
reachable drift, all three watched. Extracting `RpcFlowController` from
`RpcChannelTransport` is additionally not an RPC-25 candidate at all: there is
one copy of the credit scheme, so there is no sibling to compare it against.

That is the loop's verdict on it, and it is narrower than the owner's question.
The refactor may still be worth doing as ordinary work — the readability
argument for splitting `_fcMetered` and `_fcForget`, which each serve two
mechanisms, is untouched by any of this. It is a preference, and preferences are
the owner's to spend time on, not a round's.

**The core's witness is timeout-shaped.** `flow_control_connection_test.dart` is
the only test that catches the charge-both rule, and it catches it as a 30-second
deadlock, which `methods/canary.md` item 2 names as the weak form. Not repaired
here: the round's subject is the duplication, and rewriting a test to assert an
event rather than wait for one is a change with its own canary (L-11).

**Round cap.** 367 of 370. Opening a ~400-line extraction across a file with
eight test files reading its public diagnostics is exactly the multi-round tree
the skill says not to start near the cap — a second reason the answer would have
been "not now" even had the coverage numbers gone the other way.

## Links

- RPC-25 — the lens; `applied:` gains 367, status unchanged (partial sweep)
- C-39 — the negative this round produced
- Round 308 — the drift in this same pair that RPC-25 was derived from; fixed,
  and `metered_on_every_call_test.dart` still guards it
- Round 331 — the unequal-coverage criterion this round applied and failed to meet
- L-12 — the class was counted (three copies) before anything was touched
