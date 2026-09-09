---
file: packages/core/rpc_dart/.dart_tool/probe/watermark_survives_a_decorator.dart
round: 217 — the validating round
commit: 576f1815
paths: [packages/core/rpc_dart/lib/src/resilience/**]
status: valid
---

# P-09 — does the stream-id watermark survive a user's decorator?

`RpcClientConnection` over in-memory pairs, with a factory that builds a fresh
transport on each swap. A bidi call is opened, the connection is forced to
reconnect, a second call is opened, and then the FIRST call's teardown is sent
through the proxy onto the new transport.

Run it with `melos exec --scope=rpc_dart -- fvm dart run
.dart_tool/probe/watermark_survives_a_decorator.dart`. The knob is what the
factory returns: the transport itself, or a decorator around it.

## Measures

Two things, and the second is the one that matters:

- the id the second call is handed, against the id the first still holds;
- how many handlers ENDED after the dead call's `finishSending`, counted in the
  handler itself. An id collision is only a bug because of what it does, and
  this is the what.

## Control

The factory returns the transport unwrapped, so the `is IRpcStreamIdSequence`
check finds the capability and the watermark is carried. At validation:

```
  factory returns          id before   id after   handlers ended
  the transport itself         1           3          0 -> 0
  a plain decorator            1           1          0 -> 1
```

The decorator forwards every `IRpcTransport` member and declares nothing else —
what a metrics or auth wrapper looks like written the obvious way, and the same
shape round 209 found dropping `IRpcFlowControlled` on http2.

`0 -> 1` is a live bidirectional call whose request stream was half-closed by an
unrelated dead call's teardown, so the server finished serving it. That is the
defect `RpcClientConnection`'s own comment says the watermark exists to prevent,
reached through a different door.
