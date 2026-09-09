---
round: 224
verdict: FIXED
packages: [rpc_dart]
lens: RPC-03
bench: P-09 — reused
budget: probes 1/3, canaries 0/3
review: self — the session forbids the Agent tool unless the user asks; the `loop.py review` prompt was answered against the record, the probe and both canaries. Approved 9 of 10, A1 not applicable (no attacker/victim, this is a programmer-error refusal)
commit: yes
---

# Round 224 — refuse a transport that cannot carry the watermark

## Target

B-17, the owner decision and therefore the round's first target.

`next` named lens RPC-01 instead, and **that was a defect in the selector**:
`pending_decisions` matched `awaiting owner` only, so writing the decision was
what dropped a lead out of the priority slot — at the exact moment it became
actionable. Fixed in its own skill commit before the round proceeded; `next` now
names B-17. Recorded here because the round departed from `next` before the fix
existed.

## Hypothesis

`RpcClientConnection` carries a stream-id watermark across transport swaps, and
both hops discover the capability with `is IRpcStreamIdSequence` and return
silently when it is absent. A decorator that forwards every `IRpcTransport`
member and declares nothing else therefore erases the mechanism, and a dead
call's teardown ends a live one. Refusing such a transport at attach removes the
collision entirely.

## Before

```
P-09, reused. The knob is what the factory returns.

  factory returns          id before   id after   handlers ended
  the transport itself         1           3          0 -> 0     <- control
  a plain decorator            1           1          0 -> 1
```

`0 -> 1` is a live bidirectional call whose request stream was half-closed by an
unrelated dead call's `finishSending(1)`, and the server finished serving it.

## Mechanism

The capability is not optional for this class: without it the watermark is a
no-op in BOTH directions, `_noteIdWatermark` reads nothing and `attach` seeds
nothing, so the replacement transport restarts its sequence at 1.

Refused in `_connectWithBackoff`, immediately before `_proxy.attach(inner)`.

**Placement is the whole of the fix.** `attach` sits inside a `try` whose
`catch` retries with backoff, so throwing there would convert a programmer error
into an unbounded reconnect loop — a spin that also builds a transport per
attempt. The refusal instead closes the transport it owns, logs at `error`, emits
`RpcClientDisconnected(reason:)` and ends the loop the way an exhausted retry
budget does.

Checked before writing it, because the whole case rests on it: **every
first-party caller transport already implements the capability** — isolate,
wasm and websocket through `RpcChannelTransport`, http2 and http by declaration.
So what is refused is a hand-written decorator or mock, and those are not
working today; they lose a call on every reconnect.

## After

```
  factory returns          came online   reason names it   handlers ended
  the transport itself     yes, id 3     n/a               0 -> 0    <- control
  a plain decorator        NO, refused   true              0

  handlers ended, decorated arm:   1 -> 0
```

The control row is unchanged, which is what says the bench still sees the
mechanism rather than having been blunted by the fix.

**The probe's decorated arm was rewritten** — one against the probe budget, and
foreseen in B-17's notes. Before the fix it measured the collision; the fix
means there is no second call to collide with, so the arm now measures the
refusal. The control arm is untouched.

## Canary

Two, because the fix has two halves: refusing at all, and refusing *without*
re-entering the retry loop.

```
1. condition disabled (is! IRpcStreamIdSequence -> is! IRpcTransport)

   WITNESS the connection does not come online, and the reason says why
     Expected: <Instance of 'RpcClientDisconnected'>
       Actual: <Instance of 'RpcClientOnline'>
     attaching it would hand id 1 out twice, and the first call's
     finishSending(1) would half-close the second

   The other 6 tests in the file stayed GREEN — the new witness isolates the
   new defect rather than re-checking round 217's.

2. refuse by `throw error` instead of emit-and-return

   GUARD it is refused once, not retried forever
     Expected: <1>
       Actual: <2>
```

Canary 2 is the one worth having: the fix is correct only in that mode, and a
future edit that "tidies" the refusal into a throw would pass canary 1.

Both reverted with `Edit`; the file is at the fixed state and the suite is green.

## Gate

```
melos run analyze                No issues found!            21 packages
melos run format:check           0 changed                   21 packages
melos run test:unit --no-select  All tests passed            14 packages
```

`analyze` failed once first (an `unnecessary_import` for `dart:typed_data`,
which `rpc_dart.dart` already re-exports) and `format:check` once on the five
edited test files; both fixed, both re-run green.

The four dependent tests B-17 named — the http2 and websocket
`reconnect_close_race_test`, http's `stream_ids_survive_swap_test` and
`rpc_dart_log`'s `reconnect_test` — are inside `test:unit` and ran (22 lines in
its output). They use REAL transports, which all implement the capability, so
none needed changing.

Also, in the package: `test/resilience` 107 tests, all passed.

## Not fixed

**The blast radius landed where B-17 predicted: in the fakes.** Four hand-rolled
test transports had to declare the capability (`_Tracked` twice,
`_TrackedTransport`, `_FakeTransport`). That is 53 lines of the 207-line diff,
and none of it was a measured objection — a double that cannot report its id
cursor IS the decorator this refusal exists to catch.

**This is a breaking change** for an application with such a decorator. Versions
and the changelog are the owner's and out of the loop's scope; noted once, not
foregrounded.

**The compile-time version is deliberately not done.** An
`IRpcReconnectableTransport implements IRpcTransport, IRpcStreamIdSequence` as
the factory's return type would give a decorator author a red squiggle instead
of a runtime refusal. It is a separate breaking signature change, larger than
what was authorised, and is filed as B-21 rather than smuggled in here.

## Links

Lead `../backlog/B-17-watermark-lost-through-a-decorator.md` — closed by this
round.
Lead `../backlog/B-21-reconnectable-transport-type.md` — new, the compile-time
follow-up.
Bench `../probes/P-09-watermark-survives-a-decorator.md` — reused; its decorated
arm rewritten to measure the refusal, control untouched.
Lens `../lenses/RPC-03-stream-ids-restart-on-reconnect.md` — `applied: [224]`,
the open door closed.
Round `217-a-decorator-erases-the-stream-id-watermark.md` — the measurement.
Round `218-generation-tagging-cannot-work.md` — why the first decision could not
be built.
