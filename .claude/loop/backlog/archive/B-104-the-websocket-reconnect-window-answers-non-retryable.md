---
status: closed (round 495)
round: 495
commit: 027ca636
paths: [packages/transport/rpc_dart_websocket/lib/src/websocket_caller_transport.dart]
probe: P-133
reason: "closed — CONFIRMED with the right exception type: status 9 in the close await against 14 in the factory await, and health() read CLOSED"
---

# B-104 — websocket caller: calls made at the start of reconnect() get FAILED_PRECONDITION instead of UNAVAILABLE

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**medium-high**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

`_disconnected = true` is set only after `await _fwdSub.cancel()` and `await _inner.close()` (a websocket sink close can take seconds); in that window `_ensureUsable` passes and the send hits a closed inner, which throws `RpcClosedException` — non-retryable — where `RpcNoConnectionException(reconnecting: true)` was meant.

## The shape

`packages/transport/rpc_dart_websocket/lib/src/websocket_caller_transport.dart:562-572`:

```dart
final idCursor = _inner.lastIssuedStreamId;
await _fwdSub?.cancel();
await _inner.close();
_disconnected = true;           // only now
final ws = await _reconnectFactory();
```

The comment right there says the window was fixed; only the factory await was.

## Why it matters

Exactly the misclassification `RpcNoConnectionException` was introduced to
remove (`protocol.dart:247-265`): a caller told FAILED_PRECONDITION does not
retry a condition that resolves itself in milliseconds.

## Witness a round would build

Reconnect against a peer that is slow to answer the close handshake (delay the
server's close by 500 ms); issue a call 50 ms into `reconnect()`. Expected today:
status 9.

## Fix sketch

Set `_disconnected = true` (and the reconnecting flag) before the first await.

## Owner decision

—

## Closed (round 495) — confirmed, plus a consequence the lead does not name

```
                          status                                health
inside the CLOSE await    RpcClosedException, 9, not retryable  closed
inside the FACTORY await  RpcNoConnection,   14, RETRYABLE      degraded
no reconnect in flight    no throw                              healthy
```

The exception type is exactly as filed, and the factory arm — round 359's fixed
segment — is the control that says the 9 belongs to the segment rather than to
the rig.

**`health()` read CLOSED, which is terminal.** It delegates to `_inner` whenever
`_disconnected` is false, and the inner is already closed by then, so a supervisor
polling health during a recovery was told the transport was gone for good. Same
root cause, worse consequence than the status.

Fixed as the sketch says — the flag before the first await. The parenthetical
"(and the reconnecting flag)" needs nothing: `reconnect()` assigns `_reconnecting`
immediately after `_reconnectOnce()` suspends, and the prologue has no await
between the two lines, so no caller can observe `_disconnected` set with
`_reconnecting` still null.

Left unmeasured: how long the real window is. The bench holds it open for a chosen
600 ms; the seconds dart:io actually waits for a close frame the peer never sends
is B-134's number, not confirmed here.
