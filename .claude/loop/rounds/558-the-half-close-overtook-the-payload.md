---
round: 558
verdict: FIXED
packages: [rpc_dart_http2]
lens: RPC-01
bench: P-183 — new
budget: probes 1/5, canaries 2/5
commit: yes
release: changelog
---

# Round 558 — the half-close overtook the payload

## Target

B-184, from the audit intake, `round: — (not re-measured)`. Three claims about the http2 caller's
outgoing pump, the sharpest being that `finishSending` while a `sendMessage` is parked on the peer's
window puts END_STREAM first and the parked message is dropped — **silent request truncation**, the
class B-74 fixed in core.

Chosen by the same grading round 556 opened: this one costs the owner's own data, not a third
party's compile.

Lens RPC-01: flow control, and what happens to a frame nobody waited for.

## Hypothesis

From the lead: a parked `add` returns silently when the sink closes under it, so the send reads as
success with its payload gone.

## Before

```
  CONTROL drains throughout            data 64B eos=false, data 0B eos=true
  parked send, then endStreamNow()     data 0B eos=true        <- the 64B payload GONE
      the parked add: returned=true threw=null
  parked send, then dispose()          NOTHING
      the parked add: returned=true threw=null
```

Bench `../probes/P-183-what-reaches-the-wire-when-a-parked-send-meets-a-half-close.md`.

**Both claims confirmed, and both report success.** The CONTROL is what makes the middle row a loss
rather than a rig that never delivers payload.

## Mechanism

Two defects in one method pair, and they need different fixes.

`endStreamNow()` existed so a half-close never waits on a dead peer — correct, and it ALSO let the
END_STREAM overtake payload already queued behind the window. It added the empty frame and closed
the controller, so the parked `add` woke to a closed sink and took its `return` path.

So: **parked payload goes first.** When `endStreamNow` finds waiters it records the request and wakes
them; the woken `add` enqueues its payload and then emits the END_STREAM it owes. Nothing waits on
the peer — the controller buffers and drains when the window opens — so the property
`endStreamNow` was built for is kept.

And `add` now **throws** rather than returning when it cannot deliver. That is the half the lead
cares about most: returning normally is how a dropped payload came to read as a completed send.
`RpcStatusException(unavailable, ...)` names the stream and is retryable, which is true of a
connection that went away under a send.

## After

```
  parked send, then endStreamNow()     data 64B eos=false, data 0B eos=true
  parked send, then dispose()          NOTHING
      the parked add: returned=false threw=RpcStatusException(14): HTTP/2 stream 1
                                        was torn down before the message could be sent
```

The first row is now identical to the CONTROL. The second keeps an empty sink — correct, the owner
is tearing the stream down — and differs only in what the caller is told, which is the whole point.

## Canary

**Two, one per half, because the two defects are independent.**

```
A. the parked-payload-first branch removed
   WITNESS a half-close does not overtake a parked send
     Expected: ['data 64B eos=false', 'data 0B eos=true']
       Actual: ['data 0B eos=true']
     the payload was queued first, so it must reach the wire first

B. `add` returns instead of throwing
   WITNESS a disposed pump FAILS the parked send
     Expected: false
       Actual: <true>
     returning normally told the caller a dropped payload was sent
```

Each fails ONE witness and leaves the other green, which is what says the two halves are separate
mechanisms rather than one guard written twice.

## Gate

```
melos run analyze               SUCCESS   21 packages + rpc_dart_wasm
melos run test:unit --no-select SUCCESS   15 packages
melos run format:check          SUCCESS   0 changed
melos run license:check         SUCCESS   REUSE compliant
```

No existing test moved, which is worth noting for a change that makes a previously-silent path
throw: nothing in the suite was relying on a send reporting success after its pump was disposed.

## Not fixed

**The lead's third claim is untouched.** `sendMessage` re-adds the stream id to `_halfClosedLocal`
AFTER its await, so a cleanup that ran in between leaves one entry per stream behind. That is the
caller transport's bookkeeping rather than the pump's, it is a leak rather than a truncation, and it
needs its own rig. Left on the lead, which stays open for it.

**No end-to-end arm.** Both states are reproduced at the pump, which is where both defects live. A
client-stream against a handler that never reads would drive the same mechanism through more layers
and would not distinguish more.

**`_waiters` can still be overtaken by a NEW `add`**, which the lead names in passing: a second
`add` arriving while the first is parked does not queue behind it. Unmeasured here, and a different
shape from the half-close race — ordering between two concurrent sends on one stream is the caller's
to serialise today.

## Links

Lead `../backlog/B-184-http2-send-message-races-after-its-await.md` — two of three claims fixed, the
`_halfClosedLocal` leak left open.
Bench `../probes/P-183-what-reaches-the-wire-when-a-parked-send-meets-a-half-close.md` — new.
Round `556-no-published-core-satisfies-any-floor.md` — whose grading question picked this lead over
the pubspec kind.
Lens `../lenses/RPC-01-flow-control-credit-on-skip.md` — `applied: [558]`.
