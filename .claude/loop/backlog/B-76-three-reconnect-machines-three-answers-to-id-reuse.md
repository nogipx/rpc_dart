---
status: decided by owner (round 445)
round: 444 — re-read against the tree, never measured
commit: 67303ea6
paths: [packages/transport/rpc_dart_websocket/lib/**, packages/transport/rpc_dart_http2/lib/**, packages/core/rpc_dart/lib/src/resilience/client_connection.dart]
probe: —
reason: cost — split out of B-70 item 17; adjacent to B-21 and NOT covered by it
---

# B-76 — three reconnect machines answer id reuse three different ways

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
