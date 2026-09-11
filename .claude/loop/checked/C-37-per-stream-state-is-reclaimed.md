---
round: 343
scope: packages/transport/rpc_dart_http2/lib, packages/transport/rpc_dart_http/lib
commit: 4527416a
paths: [packages/transport/rpc_dart_http2/lib/**, packages/transport/rpc_dart_http/lib/**]
---

# C-37 — the hand-rolled transports reclaim their per-stream state

## The detector, and why it was worth running

Round 342's keeper: a field enumeration is blind to mechanisms that have no
field. `RpcChannelTransport` carries two of that kind for per-stream state, and
both exist because a stream id can be the PEER's choice:

```dart
_rememberFinished()  bounds _finishedStreams by _maxRememberedFinishedStreams
_onMessage()         gates _statusSeen on a controller existing, because
                     "ungated, a peer can grow it without limit with
                      metadata-only frames on ids we never minted"
```

Neither is named in `RpcSecurityPolicy`. Rounds 340-342 found three things the
hand-rolled transports had not ported; this asked whether these two are a fourth.

## Measured

Every per-stream collection in the four hand-rolled transports, with where it is
pruned:

```
transport        collection                pruned at                     bounded
http2 caller     _resetStreams             releaseStreamId + a CAP       256 explicit
                 _statusReceived           release, reset, onDone, close  by prune
                 _initialHeadersReceived   same four                      by prune
                 _halfClosedLocal          same four                      by prune
                 _reservedStreams          same four                      maxActiveStreams
http2 responder  _incomingStreams          releaseStreamId, close         http2 SETTINGS
                 _streamSubscriptions      onDone, releaseStreamId, close by prune
                 _streamParsers            onDone, releaseStreamId, close maxActiveStreams
                 _initialHeadersSent       releaseStreamId, close         by prune
                 _fcDeferred/_fcOutstanding
                   /_fcRefused             _fcForget from releaseStreamId by prune
http                                       _pending                       maxActiveStreams :219
  responder                                  (5 removal sites)
http caller      _pending, _inFlight       per call, + clear on close     locally minted ids
```

Two facts do most of the work. The http2 caller and the http responder mint
their own ids, so the `_statusSeen` gating problem cannot arise there — the peer
has no way to name a key. And where the id IS the peer's (the http2 responder),
the collections are bounded by `maxActiveStreams` or by http2's own
`SETTINGS_MAX_CONCURRENT_STREAMS` rather than by a remembered-set cap.

P-41, 2000 completed unary calls on ONE connection, read from the transports'
own `health()`:

```
                  after 1 call    after 2001 calls
incomingStreams              0                   0
streamSubscriptions          0                   0
streamParsers                0                   0
```

## Control

**The first ablation was silent, and that is the part worth keeping.** Deleting
`_streamParsers.remove(streamId)` from `releaseStreamId` changed nothing:

```
                                   after 1    after 2001
as shipped                         0          0
releaseStreamId's remove gone      0          0      <-- masked
BOTH removes gone                  1          2001
```

`_streamParsers` is pruned in `_handleIncomingStream`'s `onDone` as well, and
either site alone is sufficient. A single-site ablation therefore reads exactly
like a bench that cannot see a leak — which would have made this CLEAN
worthless. L-01, on a redundancy that is deliberate rather than accidental.

## What would change this

A new per-stream collection, or a new path that adds to an existing one without
going through `releaseStreamId`. The http2 responder is the one to re-check,
because it is the only one of the four whose keys the peer chooses: a collection
added there needs either a `_fcForget`-style prune or a cap, and nothing in the
type system asks for one.

Not re-checked here and out of scope for the same reason as always: the isolate
transport, whose channel cannot be reached without arbitrary code in the process
(RPC-10).
