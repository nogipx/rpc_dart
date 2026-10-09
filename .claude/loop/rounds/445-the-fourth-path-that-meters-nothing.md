---
round: 445
verdict: FIXED
packages: [rpc_dart]
lens: RPC-01
bench: P-99 — new
commit: yes
severity: S1
---

# Round 445 — the fourth path that meters nothing

## Target

B-74, the top-ranked lead, taken because the owner had just decided every live
lead in one backlog review and this one sat first on damage class: same class as
round 366, which arrived from a real user.

**Reading the code first retired the lead's premise.** B-74 says
`sendMetadata(endStream: true)` does not wait for a credit-parked send. It does —
commit `663cccec`, 2026-09-24, one day AFTER `7ec1b5d1` split B-70 into the
leads. That commit is not in the journal, which is why `loop.py next` still
listed B-74 as an owner decision pending, and why the decision written onto it
hours before this round was written against a tree that had already moved. L-13
is the rule and this is its cheapest possible instance: the round that executes
re-measured the sentence.

What survived the re-read is the FIX's own claim. `_claimEnding`'s doc said
*"Every path that can end a stream goes through here"* and the commit body said
*"every ending goes through it"*. `_claimEnding` is called from two sites;
`_markFinished` ends a stream from three more. So the scope was set before any
fix: all three bypassing sites, which is L-12's count-the-class taken up front.

## Hypothesis

An ending issued while a DATA frame is parked for credit overtakes it on any path
that does not claim the ending first. `sendDirectObject` is the sharpest case
because it takes no credit at all, so it needs no race — just a parked sibling.

## Before

```
arm                                  verdict      order at the peer
finishSending            [frame]     held back    [data:600, data:16, end]
sendMetadata(end)        [frame]     held back    [data:600, data:16, end]
finishSending            [memory]    held back    [data:600, data:16, end]
sendMetadata(end)        [memory]    held back    [data:600, data:16, end]
sendDirectObject(end)    [memory]    OVERTAKEN    [data:600, direct, end, data:16]
sendMessage(end) fast    [frame]     0 of 200 attempts
```

Probe: `packages/core/rpc_dart/.dart_tool/probe/ending_paths_overtake.dart`

**The first build of this probe was void in both arms under test**, and both
failures read as passes — L-15 twice in one round. `sendDirectObject` threw
`UnsupportedError` because `RpcChannelTransport.pair()` is the frame codec path
and has no zero-copy; `memoryPair()` does. And `sendMessage(end)` PARKED instead
of taking its fast path, so it measured the parked branch a second time and
reported "held back".

## Mechanism

`sendDirectObject` wrote its frame with the end flag and called `_markFinished`
afterwards. A direct object is never metered — it does not call `tryConsume` at
all — so nothing made it wait for a `sendMessage` still sitting in
`awaitCredit`. The peer then saw a stream that finished, counted what arrived,
and was one frame short while the sender believed it had sent everything. That is
the shape RPC-01's detector already names: *"`sendMessage` as the sole consumer
of credit"* — the sole consumer is exactly why the other paths carry no weight of
their own.

## After

`sendDirectObject(end) [memory]` reads `held back`:
`[data:600, data:16, direct, end]`. The other five rows are unchanged.

## Canary

`_claimEnding`'s call removed in place from `sendDirectObject`. The witness
failed — not on a timeout:

    Expected: a value greater than <3>
      Actual: <2>
    the direct object ended the stream while a DATA frame was parked for
    credit, so the peer ends a frame short:
    [data:600, direct, end, data:16]

`+3 -1`, the only red being the new witness; the three controls stayed green,
which is the virtue that says the witness isolates this defect.

One canary, because the fix is now one half. The second half — a synchronous
parked-check on `sendMessage`'s fast path — was written, could not be killed by
any witness, and was **dropped rather than committed**. Round 366 set that
precedent in this same file for the same reason.

## Gate

`melos run analyze` clean over 21 packages plus rpc_dart_wasm. `test:unit`
SUCCESS over 14 packages (`rpc_dart` 1658 passed 1 skipped). `format:check`
SUCCESS. `license:check` green after the fix below. In the changed package:
`fvm dart analyze lib test` clean, `fvm dart test -j 8` 1658 passed 1 skipped.

**`license:check` was RED before this round touched anything**, on
`.devtrack/devtrack.db` and its two WAL sidecars — binary runtime state that
cannot carry an SPDX header, untracked, present since before the session.
Gitignored here, the same remedy and the same reasoning `.mcp.json` carries three
lines above it, rather than left for the next round to trip on.

**The web target could not be completed and is not claimed.** `fvm dart test
-p node` dies with `read ENETDOWN` (errno -50) while node connects to the test
channel — in `loading`, before any test code runs. It hits files this round never
touched, does not respond to `-j 2`, and struck a file that had passed alone
minutes earlier, so it is the machine's loopback and not the change (L-14's tell:
it does not respond to the remedy its symptom suggests). This round's own witness
DOES run there: 4 of 4 green under `-p node`.

**`config.md` was modified by something that was not this round, and is NOT in
its commit.** `probes: 3 / canaries: 3 / round cap: 460` became `5 / 5 / 480`
between the first `git status` of the session and the last. No `Edit` here
touched it, and the only commands run in between were `loop.py next`, `brief`,
`review` and `lint` — all four of which the skill documents as reporting facts,
with `sync-index` named as the one that writes. So either one of them writes
undocumented, or the owner changed it mid-session. Left in the working tree for
the owner rather than ratified by this round's commit; the values this round
actually ran under were the new ones, and it used 2 probe builds and 1 canary, so
the difference does not reach the verdict.

## Not fixed

**`sendMessage`'s fast path, `channel_transport.dart:506`.** It ends a stream
without claiming the ending, and the probe could not reach it: 0 of 200 attempts,
before and after. That zero is void, not clean — the fast path fires only while
credit is positive and a parked frame means credit is negative, so the two
preconditions exclude each other except in the single turn a grant lands. Filed
as **B-88** with the construction that would be needed.

**`sendMessage`'s parked branch, `:494`, deliberately left.** It IS the parked
send: `_claimEnding` awaits `_parkedSends[streamId]`, which on that path is this
very send's own completer, completed only in the `finally` below it. Routing it
through would self-deadlock. Now written on `_claimEnding` as the one stated
exception, in place of the claim that there were none.

## Links

- RPC-01 — flow-control credit on the skip path; its detector names the sole
  consumer of credit, which is the fact this turns on
- P-99 — which ending paths wait for a credit-parked send
- P-58 — corrected: its "a pair never parks" is about the LATENCY-shaped park,
  not this volume-shaped one
- B-74 — closed by this round plus `663cccec`
- B-88 — new, the unreachable fast-path arm
- Round 366 — the same rule, the first path, and the precedent for dropping an
  unwitnessed half
- L-12 (count the class first), L-13 (re-measure the sentence a decision was
  taken on), L-15 (a void arm reads like a clean one, twice)
- Witness: `test/transports/end_of_stream_waits_for_a_parked_send_test.dart`
