---
round: 484
verdict: DEFERRED
packages: [rpc_dart_wasm]
lens: RPC-06
bench: none — an owner decision, not a measurement
commit: yes
severity: S1
---

# Round 484 — the owner emptied the backlog

## Target

The four remaining leads, closed on the owner's instruction. Asked whether any
of them was critical and told no, the owner answered: *"close them so they stop
getting in the way."*

DEFERRED, not CLEAN: nothing was measured here and one real defect is being left
standing. A round that closes leads without fixing them must say so in its
verdict rather than let an empty backlog read as a finished one.

## Hypothesis

None to test — the round carries out an instruction rather than checking a
claim. What it CAN get wrong is the accounting: a closure that drops the
reasoning reads later as "someone looked and found nothing", which is the
opposite of what happened. So the working question is which of the four cost
something to close, and that is answered per lead below.

## Before

```
B-10   open, a deferral since round 223
B-35   decided by owner — report written, only posting left
B-38   open — real defect, fix written, witness refuted
B-93   open — premise already dissolved by round 482
```

## What was closed, and what each closure costs

```
B-10   a deferral since round 223, never a defect       costs nothing
B-35   dependency bug this library cannot reach         costs nothing
B-93   round 482 had already dissolved its premise      costs nothing
B-38   a REAL defect, iOS-only, unreproduced            costs something
```

**B-38 is the one with a price**, and it was named before the closure rather
than discovered after: iOS's recv loop catches, sets `_recvRunning = false` and
does nothing else, so where it stops host-to-guest stops, `recvQueue` grows on
the Swift side, and in-flight calls wait out a deadline that is OPTIONAL on this
transport. Android reports death; `RpcWasmBridge`'s contract promises it. All
still true.

What the closure decides is that 27 rounds of attention on an unreproduced,
iOS-only, one-package defect is enough. That is a judgement about cost and it is
the owner's to make.

## Mechanism

Status changed on four leads, each with a section saying **why it closed and
what would reopen it**. Nothing was deleted: B-38 keeps its written and
type-checked four-step fix and the refuted witness; B-35 keeps the verified,
duplicate-checked, runnable upstream report.

A closure that removes the reasoning is the expensive kind — it reads later as
"someone looked and found nothing", which is the opposite of what happened.

## After

```
B-10   closed (484)   costs nothing — never a defect
B-35   closed (484)   costs nothing — report kept, verified, unposted
B-93   closed (484)   costs nothing — measurement kept
B-38   closed (484)   the defect STANDS, unfixed and recorded as such
```

Open leads 3 -> 0, owner decisions outstanding 1 -> 0. **The backlog is empty
and the tree is not clean of defects**, and those are different sentences.

## A live thread cut mid-read, recorded so it is not lost

Round 484 was reading `SchemeHandler` when the instruction arrived, and had
reached a specific doubt about round 472's refutation — the thing that has
blocked B-38 for eleven rounds.

`/recv` has TWO branches (`RpcDartWasmPlugin.swift:476`): if `recvQueue` is not
empty the task is answered immediately and `pendingRecvTask` is never touched.
**So the supersede only fires when the queue is empty at that instant.** Round
472's witness ran a normal call immediately before the break, which is exactly
what leaves bytes queued.

If that is right, its three identical greens mean *"the supersede never
happened"* rather than its stated *"a supersede is followed by a success"* — and
the route it declared dead may be alive with different timing. Unverified, and
now not going to be. It is written into B-38 so no future reader inherits round
472's conclusion as settled.

## Canary

None, and none is possible: nothing was fixed. Recorded as a gap rather than
skipped — `## Canary` empty on a FIXED round is an error, and this round is
DEFERRED precisely because it has nothing to switch off.

## Gate

`melos run analyze` SUCCESS, `format:check` SUCCESS, `license:check` SUCCESS,
`test:unit --no-select` SUCCESS over 15 packages. No source changed at all; the
gate confirms the tree is where round 483 left it.

## Not fixed

**B-38's defect, explicitly.** It is closed, not repaired. A field report of an
iOS wasm call hanging after the app is backgrounded would both reopen it and
supply the `webView(_:stop:)` witness nobody could construct.

**The two stale lens sweeps.** RPC-09 and RPC-14 are still marked `swept here` at
`7ee3e602` with 17 and 15 files moved since, and `loop.py next` will keep
reporting it. A reading-level pass narrowed the two to ONE new `.timeout(` site,
in `unary/caller.dart`, which is the inverse of RPC-14's shape — the timeout
exists to guarantee the stream id is RELEASED, and the abandoned value is a void
send rather than a handle. Not filed as CLEAN: that needs a bench, and reading
is not one.

## Links

- B-10, B-35, B-38, B-93 — all four closed here
- Round 482 — which had already dissolved B-93
- Round 480, 483 — which finished B-35's report to the edge of posting
- Round 472 — whose refutation of B-38's witness is now doubted in writing
