---
round: 481
verdict: INCONCLUSIVE
packages: [rpc_dart_wasm]
lens: RPC-11
bench: none — the instrument is the lead's own two sections read against each other, then one device run
commit: yes
---

# Round 481 — the lead that kept asking for a device it already had

## Target

B-38, because `loop.py status` has been naming it *"THE ROUND'S FIRST TARGET"*
for nine rounds with the sentence **"Boot a simulator and the round finishes"**
— and the same file says, higher up, that a round already did that and it did
not finish.

Not a code defect. A defect in the loop's own data, which rule one covers in
full, and one with a measurable cost: a round taking the lead at its word spends
itself rebuilding a void arm.

## Hypothesis

One of the two statements is stale. Read the round that wrote each.

## Before

They are nine rounds apart and they contradict on the central fact.

```
B-38, top section (round 472)    "no longer waiting on a device -- the device
                                  works. It is waiting on a witness design"
B-38, ## Owner decision (415)    "it needs a device, not a decision. Boot a
                                  simulator and the round finishes"
B-38, frontmatter reason:        "the witness needs a booted iOS simulator and
                                  none could be started in this session"
```

Round 472's record settles it — the simulator booted, all four steps of the fix
were reapplied, `analyze:native` passed, the specified witness was built, and:

```
with the fix (retry + report)           +27  All tests passed!
CANARY: no retry, give up on failure 1  +27  All tests passed!
CONTROL: the ORIGINAL recv loop         +27  All tests passed!
```

Identical, the original included. The arm is VOID, for a reason that is in this
lead's own premise: a supersede replaces the pending task with one that is then
ANSWERED, so the loop's next poll succeeds and host-to-guest never stops.

**`## Owner decision` is the section `loop.py status` prints.** So the stale
half is the one every future round reads, and it points at an action that has
already been taken and shown not to work.

## Mechanism

The owner's words are not rewritten — they stand unedited under a heading that
says when they were taken. Above them, a note recording that the decision was
carried out and its premise did not hold. The frontmatter `reason:` is replaced,
since it described a blocker that no longer exists.

Status moves `decided by owner` -> **`open`**, and the first attempt at this
round got it wrong by writing `awaiting owner`. That over-claims: round 472 says
what remains is a witness DESIGN, which is a round's work, and of the three
routes this lead names one is refuted and **two are untried**. Nothing has
established that no witness can be built, so there is no question to ask yet.
The owner's standing calls — no `analyze:native`-only, no fix without a witness
— are unchanged and still bind.

## After

The device half re-measured rather than argued, because "the device is not the
blocker" is exactly the kind of claim this round exists to stop inheriting.

```
Android, physical Pixel 8, Android 16 / API 36   +24 ~2  All tests passed!
iOS simulator, this session                      never registers
```

The Android run is **stronger evidence than the record had**: every previous run
was an emulator at API 30, and this is real hardware six API levels up, clearing
`androidx.javascriptengine`'s `minSdk = 26` by a wide margin. Same result,
`+24 ~2`, so the suite is not emulator-dependent.

The iOS half is unavailable *here* — `fvm flutter emulators --launch
apple_ios_simulator` returns silently and the device never appears, and `xcrun`
is not in the allowlist. That is an environment fact about this session, and the
repair is careful to say so rather than writing it back into the lead as a
property, which is how the original stale sentence was created.

## Canary

No fix, so nothing to switch off. What stands in its place is that **the two
sources were read separately and disagree** — the contradiction is the finding,
and round 472's three-arm table is what decides which side is right. Had only
the `## Owner decision` section been read, the round would have gone looking for
a simulator.

The Android run is its own control in the weak sense that matters here: it shows
the device path still works end to end, so "iOS does not register" is about iOS
and not about a broken toolchain.

## Gate

`melos run test:wasm:device` on the Pixel 8: `+24 ~2 All tests passed!`. No
library code changed, so the ordinary gate is unaffected; the tree was clean
before this round's records.

## Not fixed

**B-38's actual defect.** iOS still does not report a dead recv loop, and
`RpcWasmBridge`'s contract still promises it does. Nothing shipped and nothing
should: the owner declined `analyze:native`-only, correctly, and no witness
exists.

**No witness was designed**, which is the lead's real remaining work. Round 472
names the two untried routes — `webView(_:stop:)` under memory pressure, or a
navigation the guest triggers — and says both risk tearing down more than the
recv task. Attempting either needs an iOS device, which this session cannot
boot, so trying it blind would produce exactly the kind of unfalsifiable green
round 472 refused.

**No question was put to the owner, and an earlier draft of this round wrongly
did.** Asking "what should this ship on if no witness can be built" presumes
what two untried routes have not established. The status is `open`; the work is
a round's.

## Links

- L-13 — a decision inherits the sentence it was taken on. Third instance in
  three rounds and the most expensive shape yet: here the sentence was refuted
  in writing, in the same file, and the refutation did not reach the section the
  tooling reads
- RPC-11 — the package outside the gate; fourth round running
- L-15 — why round 472's three identical greens are a void arm and not a pass
- B-38, round 472, round 470
