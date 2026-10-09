---
status: closed (round 465)
round: 449 — the silent-drop claim MEASURED and REFUTED; re-scoped to the answer
commit: 3f88d9fa
paths: [packages/transport/rpc_dart_websocket/lib/**, packages/transport/rpc_dart_http2/lib/**, packages/core/rpc_dart/lib/src/resilience/client_connection.dart]
probe: packages/transport/rpc_dart_http2/.dart_tool/probe/send_during_the_factory_await.dart
reason: cost — the three machines tell the caller three different things about one state, and http2 disagrees with itself depending on timing
---

# B-76 — three reconnect machines answer id reuse three different ways

## CLOSED (round 465) — the id-reuse half is CLEAN

One call left open across one reconnect, then the late `finishSending` this
lead's own body names as the cost of a collision:

```
             before  after  collision  late finishSending
websocket      1       3       no      no -- different id
http2          1       3       no      no -- different id
proxy          1       3       no      no -- different id
```

Control — `_nextStreamId = 1` restored in http2's reconnect — reads
`1 / 1 / YES / YES`, so the bench can see it. Negative: `checked/C-53`.

**And they must not be merged.** The three are not three answers to one question:
the websocket keeps its transport object and must REJECT ids from a dead
connection, http2 keeps its object and need only not rewind, and the proxy
REPLACES the transport so the sequence has to cross an object boundary. The third
cannot use either of the first two.

The control also showed the proxy's `_idWatermark` holding across a transport
that rewinds its own ids — which its doc comment claims and nothing had
exercised.

## STEP 2 DONE (round 464)

The `## Ask` the owner attached, answered by measurement: **neither machine's
behaviour, because the question has two answers.** Two arms per machine, a send
during a reconnect that is IN FLIGHT and one after a reconnect that FAILED:

```
                          websocket   http2     health
during the factory await     9          14      degraded
after a FAILED reconnect     9           9      unhealthy
```

Both machines gave ONE status to TWO states, and `health()` already told them
apart. A reconnect in flight is transient with the remedy already running —
UNAVAILABLE. A failed one needs `reconnect()` — FAILED_PRECONDITION.

The websocket's answer was a prior round's deliberate decision resting on a
written-down sentence: *"a synthetic UNAVAILABLE ... invites the caller to repeat
what cannot work"*. Measured (P-114), that sentence is false for this state,
because a retry backs off:

```
a retried call fired 100 ms into an 800 ms window
  FAILED_PRECONDITION   status=9 after 0ms     never retried
  UNAVAILABLE           OK pong after 711ms    retried, succeeded
```

Shipped: `RpcNoConnectionException(what, reconnecting:)` in core, thrown by all
three machines, each reading a field it ALREADY had for "an attempt is in flight"
— the two transports' single-flight future and the proxy's `_connectingGuard` —
rather than a new bool that would need clearing at three, three and seven exits.

**What is left here**: the id-reuse mechanisms. A `Set` of live ids, a never-reset
counter, and an id watermark, all solving one problem three ways. Round 464
changed none of them.

## RE-SCOPED (round 449). The silent drop is NOT there — `checked/C-48`.

Measured on http2 with the factory stalled 800 ms and a send 200 ms in:

```
control, no reconnect        ACCEPTED
during the factory await     RpcStatusException code=14   <- refused
after reconnect completed    ACCEPTED
during the await: disconnected=false
```

So the flag-timing window is real, exactly as the body below says, and **nothing
is lost in it**: the old connection is discarded before the await, so the send
path answers UNAVAILABLE. The proxy cannot have the defect at all — `_inner` is
nulled before any factory runs and `_require()` throws on null, so its guard is
an absence rather than a boolean whose timing could be wrong.

**The owner's step one — port the `_disconnected` guard to the other two — is
therefore refuted and must not be carried out.** Step two survives, and the round
sharpened what it is about:

```
websocket   _disconnected before the await   FAILED_PRECONDITION
http2       old connection discarded         UNAVAILABLE   (during the await)
http2       _ensureUsable, flag set          FAILED_PRECONDITION
the proxy   _inner = null, _require()        FAILED_PRECONDITION
```

http2's `_ensureUsable` carries a comment saying its code matches the websocket
sibling *deliberately*, because no single `catch` covered both otherwise. Timing
alone undoes that: FAILED_PRECONDITION says *call reconnect()*, UNAVAILABLE says
*retry*, so a caller's strategy depends on how far into a reconnect its send
landed.

**What is left to do**: bench the websocket arm, which was only READ, and then
decide what one state should tell a caller. The id-reuse half of the body below
is untouched by this round.

`websocket_caller_transport.dart`, `rpc_http2_caller_transport.dart` and
`_ReconnectingTransportProxy` (`client_connection.dart:78`) each solve the SAME
stream-id-reuse problem, and each solves it differently:

```
  websocket   a Set of live ids           _idsOnThisConnection
  http2       never resets _nextStreamId  :1783-1800
  the proxy   an _idWatermark             :113-132 / :163 / :342
```

**One fix exists in one of the three.** The websocket transport sets
`_disconnected` at `:416` BEFORE `await _reconnectFactory()`, above a comment
describing exactly what the other shape costs:

> Set only in the catch below, it was false for the whole factory await … so
> `_ensureUsable` passed and work went into the CLOSED inner: sends accepted and
> dropped silently.

http2 sets it only in the catch (`:1827`).

**Adjacent to B-21, not covered by it.** B-21 was about making the capability a
compile-time TYPE; it has been closed (round 430). This is about the three
machines disagreeing, which a type does not settle.

The lens to carry is RPC-25's round-444 note: the instance can be an ABSENCE, so
enumerate by what the machines DO, not by grepping the field name — the copy
without the guard does not contain the string.

L-16 applies directly: the answer is what the websocket sibling AVOIDS, and an
absence is invisible in a diff.

## Owner decision

**Take it, in two steps, and do not stop after the first.**

1. Port the `_disconnected`-before-`await _reconnectFactory()` guard to http2
   and to `_ReconnectingTransportProxy`. This is the confirmed defect — sends
   accepted and dropped silently for the whole factory await — and the websocket
   sibling already carries both the fix and the comment explaining the cost.
2. Then make the three machines ONE. Three answers to one question is the
   lead's actual finding, and step 1 alone leaves it standing.

Step 2 needs the `## Ask` answered explicitly before any code: if the three were
one, whose behaviour would the shared version have, and which of the three does
that CHANGE? Bring that answer back rather than picking the most general.

Enumerate by what the machines DO, not by grepping the field name — RPC-25's
round-444 note and L-16: the copy without the guard does not contain the string,
and an absence is invisible in a diff.
