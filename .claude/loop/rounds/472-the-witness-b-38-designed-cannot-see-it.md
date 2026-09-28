---
round: 472
verdict: INCONCLUSIVE
packages: [rpc_dart_wasm]
lens: RPC-11
bench: none — the bench is a booted simulator, and the arm built on it turned out VOID
commit: yes
---

# Round 472 — the witness B-38 designed cannot see the defect

## Target

B-38, unblocked for the first time. Round 470 showed the recorded blocker was a
stale sentence; the real one was that every simulator's data directory was
missing from disk — and since `CoreSimulator/Devices` did not exist at all, there
were no contents for `xcrun simctl erase` to destroy. That was a bad call in
round 470, corrected here:

```
xcrun simctl erase 63B170FA-...    (no output)
xcrun simctl boot  63B170FA-...    iPhone 16 Pro (Booted)
fvm flutter devices                iPhone 16 Pro • ios • iOS-18-6 (simulator)
```

So the round the lead has been waiting thirteen rounds for could finally run.

## Hypothesis

The lead's, taken at face value: the recv loop's `.catch` is reachable from the
guest by superseding the host's single pending `/recv` task, so a retry can be
witnessed by breaking the loop and making a call afterwards.

## Before

```
the recv loop's .catch    _recvRunning = false;   // and that is all
Android's sibling         reportDeath(runtimeId, ...) and break
```

Nothing restarts it and nothing reports it, so `recvQueue` grows on the Swift
side and every in-flight call waits out a deadline that is OPTIONAL on this
transport. That reading is unchanged and is not what this round disputes.

## What was built

All four steps of the fix the lead specifies, reapplied and type-checked:

1. `_rpcReportDied(reason)` posting to a new `rpcDied` handler, wrapped in
   try/catch with a `console.error` fallback — a postMessage, not a fetch,
   because the only caller is the recv loop giving up on that very scheme.
2. Retry in the `.catch`: count consecutive failures, reset on any successful
   poll, give up past 5 — backing off through `_nativeSetTimeout`, not the
   hoisted polyfill.
3. `rpcDied` registered and unregistered beside `rpcBoot`/`rpcConsole`.
4. Routed as every other pre-boot failure is:
   `if booted { reportDeath } else { finishBoot }`.

`melos run analyze:native`: **PASS swift / PASS kotlin**.

And the witness the lead designed: a `BreakRecvLoop` guest method issuing a stray
`fetch('rpc-wasm:///recv')` through `dart:js_interop`, to supersede the loop's
pending task — with a control call before and a real call after.

## The measurement, and why it is INCONCLUSIVE

Three device runs on the iPhone 16 Pro simulator:

```
with the fix (retry + report)          +27  All tests passed!
CANARY: no retry, give up on failure 1 +27  All tests passed!
CONTROL: the ORIGINAL recv loop        +27  All tests passed!
```

**Identical on all three.** The arm cannot see the defect, so it is VOID and
nothing here is evidence about the fix.

## Why it is void, which is the round's actual finding

B-38 states: *"a second request for `/recv` fails the first with
`didFailWithError(code -5, 'superseded by new recv')`. The second is reachable
from inside the guest, **which is what makes a witness possible at all**."*

Reachable, yes. Sufficient, no — and the reason generalises: **a supersede
replaces the pending task with one that is then ANSWERED.** The loop's poll
rejects once, the loop's NEXT poll succeeds, and host-to-guest never stops. That
is why the "after" call returns on the original code as readily as on the fixed
one.

The same property kills the second arm. An attempt to drive the give-up ceiling
with six supersedes — spaced 300 ms apart, deliberately ahead of the 50 ms x N
backoff, after six-at-once measured nothing — left `isDead` false:

```
6 supersedes at once        isDead=false
6 supersedes, 300ms apart   isDead=false
```

Five CONSECUTIVE failures cannot be produced this way at all, because every
supersede is followed by a success that resets the count. The ceiling is
reachable only through the lead's other route — `webView(_:stop:)` under memory
pressure or a navigation — which no test can ask for.

## Mechanism

None shipped. **The fix is reverted**, along with its guest method and its test.

That is the lead's own instruction (*"Do not 'fix' it without a witness"*), the
owner's declining of `analyze:native`-only, and round 348's rule about what a
gate never shown to fail is worth. A test that passes on broken code is worse
than no test: it converts an open question into a false answer.

## After

Unchanged — the tree is back to where round 470 left it. The round's output is
the refutation, not a diff.

## Canary

The canary is the finding. Removing the retry — the more aggressive of the two
halves — changed nothing, which is what a void arm looks like from the inside.
Had only the fix been run, `+27` would have read as success.

## Gate

`melos run analyze:native` PASS/PASS on the fix before it was reverted.
`melos run test:wasm:device` green on iOS (`+27`) in all three configurations and
on Android (`+24 ~2`, round 470). Tree restored: `git status` clean apart from
the untracked config the owner owns.

## Not fixed

**B-38 itself, and now for a better-understood reason.** It is no longer "waiting
for a device" — the device works. It is waiting for a witness design, and the one
in the lead is refuted.

What would work, for whoever takes it: the `webView(_:stop:)` route, driven by
something a test CAN ask for. Candidates not tried here — a navigation the guest
triggers, or a second `WKWebView` allocated to force memory pressure — both of
which risk tearing down more than the recv task, which is why neither was
attempted blind at the end of a long session.

## Links

- RPC-11 — the package outside the gate; this is its third round running, and
  the first where the device was available and the LEAD was the thing at fault
- L-15 — a void arm reads like a clean one. Three runs and two arms here, all
  void, all green
- L-13 — round 470 corrected this lead's blocker; this round corrects round
  470's own judgement that erasing would destroy contents, and then the lead's
  witness design
- B-38, round 470
