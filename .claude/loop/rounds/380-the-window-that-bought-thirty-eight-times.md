---
round: 380
verdict: RETRACTED
packages: [rpc_dart_websocket]
lens: RPC-15
bench: P-69 — new
commit: yes
---

# Round 380 — the window that bought thirty-eight times

## Target

B-47, which the owner had just decided: derive `initialSendWindowBytes` from
`maxMessageSize`. The decision was taken on this record's own claim, written by
me in round 366:

> **The park buys nothing that can be named.** The data still goes out — a round
> trip later, once the peer's first grant lands.

Before changing a shipped default, measure the claim it rests on. RPC-15.

## Hypothesis

The claim holds, and the only question is the relation to use.

**It does not hold.** The field's own doc comment contradicted it with numbers —
156.25 MiB without the window against 4.05 MiB with it — and
`measurement.md`'s standing rule is that a measured table inside a doc comment
is a record of someone else's run rather than evidence. So it was measured
again, and the doc was right.

## Before

A handler that never reads, 4 KiB frames, 40000 offered, real websocket through
toxiproxy at 50 ms RTT, sampled at 3 s. What got out before the first grant
could throttle anything:

```
policy                            frames      MiB
no initial window (5.0.1 shape)    40000   156.25
64 KiB (shipped default)            1039     4.06
= maxMessageSize (16 MiB)           5108    19.95
= maxMessageSize / 16 (1 MiB)       1278     4.99
```

Probe:
`packages/transport/rpc_dart_websocket/.dart_tool/probe/initial_window_what_it_buys.dart`
(P-69).

The first two rows reproduce the doc comment to within 0.01 MiB. **The window
buys a factor of 38.**

## Mechanism

Both statements are true of different things, and round 366 generalised the
narrow one.

For ONE message larger than the window, the park really does buy nothing: the
gate admits on `credit > 0` rather than on whether the message FITS, so the
first frame passes whatever the window is and drives the balance negative. That
is what round 366 measured, on frame counts of 2, 3 and 8.

For a BURST it is the opposite. From the second frame on, the window is the only
thing bounding a sender that has not yet received a grant — credit does not
exist until then — and a burst is precisely what the field exists for. Round 366
never ran a flood, so it never saw the regime the field was built for.

And the decision's own shape makes it worse rather than better: deriving the
window from `maxMessageSize` yields 16 MiB, which is **five times weaker** than
the shipped default (19.95 against 4.06 MiB).

Worth keeping: the defect round 366 actually found — `finishSending` overtaking
a parked send — is fixed. What remained was the parked state, and a park of one
round trip is not a defect. It is flow control doing its job.

## After

Nothing changed in the library. The default stands at 64 KiB.

The numbers are pinned instead, by
`packages/transport/rpc_dart_websocket/test/initial_window_bounds_a_flood_test.dart`:
a flood with the shipped window against the same flood with `null`, so the next
round to read "the park buys nothing" has a test that says otherwise.

## Canary

The witness fails without the mechanism, which is the same thing a canary shows:
with `initialSendWindowBytes: null` the caller sends **40000 of 40000** frames
against fewer than 10000 with the default, and the test asserts both against one
absolute bound rather than against each other as a ratio (tests.md item 3).

The arm that would have been the fix is its own control: 16 MiB let 5108 frames
out where 64 KiB let 1039.

## The witness had a second ceiling in it, found when the gate went red

The test shipped by this round failed in the workspace run: the unbounded arm
reported **16342 of 40000** against a threshold of 20000, with its own message —
*"this rig is not reaching the regime"* — which is the check working.

First reading was that the machine was busy under a thousand parallel tests, and
the fix was to poll to the threshold instead of counting after a fixed sleep
(`tests.md` item 1, quoted in that very file and not applied). **It changed
nothing: still exactly 16342, after polling twenty seconds.** An identical number
is not a slow machine.

16342 x 4 KiB is 63.8 MiB, and the connection window
(`flowControlConnectionWindowBytes`) defaults to 64 MiB. **With the initial
window off, the sender is still bounded — by the next window up.** A threshold
above that is unreachable by construction.

So the arm named "no initial window (5.0.1 shape)" in the table above is
unbounded only with respect to THIS window, and P-69's 156.25 MiB was measured
where the connection window was not the binding constraint. The round's
conclusion is untouched — 4.06 against 63.8 MiB is the same factor of 15 in the
same direction — but the word "unbounded" was doing more work than the
measurement supports, and the threshold now sits at 8000 frames with the ceiling
written down beside it.

**A number identical across runs is a ceiling, not a flake**, and the remedy
that fits a flake — waiting longer — is what tells them apart.

## Gate

`fvm dart test` in the changed package green (the two new tests plus the
package's own suite). No library code moved, so round 379's four-gate pass
stands.

Environment left as found: the toxiproxy container this round created was
removed; the other project's was not touched.

## Not fixed

**The owner's decision is not carried out, and that is the point of the
verdict.** It was taken on my claim, the claim was wrong, and carrying it out
would weaken a real protection fivefold. Reported before acting rather than
after.

**What the owner asked for instead**: raise the window in the CONSUMER's policy,
where the chunk size is known (rhyolite chunks at 256 KiB). That is the right
home for it — the library keeps a safe default and the application that knows
its own traffic tunes it. Not this repository's work.

## Links

- RPC-15 — the lens; `applied:` gains 380
- B-47 — retracted by this round
- P-69 — the bench
- Round 366 — where the claim was written, and what it actually measured
- P-58 — the neighbouring bench, whose lesson (an in-process pair flattens a
  latency gap) is why 366 could write this in good faith
