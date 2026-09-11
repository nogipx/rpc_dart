---
round: 343
verdict: CLEAN
packages: [rpc_dart_http2, rpc_dart_http]
lens: RPC-10
bench: P-41 — new
commit: yes
---

# Round 343 — the ablation that was masked

## Target

Round 342's keeper, applied: after the policy FIELD names, read the shared
layer's bodies for mechanisms that have no name. `RpcChannelTransport` carries
two for per-stream state, and both exist because a stream id can be the PEER's
choice:

```dart
_rememberFinished()  bounds _finishedStreams by _maxRememberedFinishedStreams
_onMessage()         gates _statusSeen on a controller existing, because
                     "ungated, a peer can grow it without limit with
                      metadata-only frames on ids we never minted"
```

Rounds 340, 341 and 342 each found something the hand-rolled transports had not
ported. This asked whether these two are a fourth.

## Hypothesis

They are. Three for three is a pattern, and an unbounded map keyed on a
peer-chosen id is the highest-severity shape of the four.

## Before

Wrong, and the reading says why. Every per-stream collection in the four
hand-rolled transports is pruned, and the two that could grow without one are
capped:

```
http2 caller     _resetStreams             CAP of 256, explicit
                 4 more sets               pruned at release/reset/onDone/close
http2 responder  _streamParsers            maxActiveStreams + 2 prune sites
                 _incomingStreams          http2 SETTINGS_MAX_CONCURRENT_STREAMS
                 _fc{Deferred,Outstanding,Refused}   _fcForget from releaseStreamId
                 2 more                    pruned
http responder   _pending                  maxActiveStreams at :219, 5 prune sites
http caller      _pending, _inFlight       per call, cleared on close
```

**Two facts do the work, and neither is a port.** The http2 caller and the http
responder mint their own ids, so the `_statusSeen` gating problem cannot arise —
the peer has no way to name a key. Where the id IS the peer's (the http2
responder), the bound is `maxActiveStreams` or the protocol's own concurrency
setting, not a remembered-set cap.

P-41, 2000 completed unary calls on ONE connection, read from the transports'
own `health()` details:

```
                  after 1 call    after 2001 calls
incomingStreams              0                   0
streamSubscriptions          0                   0
streamParsers                0                   0
```

## Mechanism

Not a defect, so the mechanism is why the hypothesis was wrong. **A missing port
only matters where the hand-rolled transport faces the same threat**, and these
two do not:

- the gating of `_statusSeen` defends against a peer NAMING a key. Two of the
  four transports mint their own ids, so there is no key to name.
- the cap on `_finishedStreams` bounds a remembered set. The http2 responder,
  which does take the peer's ids, bounds the same exposure with
  `maxActiveStreams` and `SETTINGS_MAX_CONCURRENT_STREAMS` — a different
  mechanism for the same job, which a "did they copy it?" reading scores as a
  miss.

## After

Nothing changed. The verdict is CLEAN and the audit is filed as **C-37** so the
next round starts from it instead of redoing it.

## Canary

**The first ablation was silent, and that is the round.** Deleting
`_streamParsers.remove(streamId)` from `releaseStreamId` changed nothing:

```
                                   after 1    after 2001
as shipped                         0          0
releaseStreamId's remove gone      0          0      <-- masked
BOTH removes gone                  1          2001
```

`_streamParsers` is pruned in `_handleIncomingStream`'s `onDone` too, and either
site alone suffices. A single-site ablation therefore produces the identical
output to a bench that cannot see a leak at all — and had I stopped there, this
round would have recorded CLEAN on a bench with no demonstrated sensitivity,
which is the one thing `loop.py review`'s Q2 exists to prevent.

## Gate

No library change. `git diff --stat packages` empty after restoring both
ablations, verified before committing.

## Not fixed

Nothing to fix. The RPC-10 thread that rounds 340-343 opened is now worked out
on the dimensions that terminate: policy fields (341), unnamed mechanisms in
`_validateInbound` (342), per-stream state (343). What remains under the lens is
open-ended reading, which near the cap is the wrong shape of work.

## Links

RPC-10 (`applied:` gains 343, its fourth and the first that did not pay).
L-01 — *when a fix has two halves, check whether one masks the other's witness* —
applied to a redundancy that is deliberate rather than accidental, which is a
case its own record does not cover.

> **A three-for-three streak is what made the wrong hypothesis comfortable.**
> Rounds 340, 341 and 342 each found a missing port, so a fourth felt likely
> enough that the silent first ablation could have been read as "nothing to see"
> instead of "the instrument is blind". The streak is not evidence about the
> next case.
