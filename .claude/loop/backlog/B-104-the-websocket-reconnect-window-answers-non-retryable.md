---
status: open
round: — (not re-measured) — filed by the external audit of 2026-09-28
commit: 8253fe8a
paths: [packages/transport/rpc_dart_websocket/lib/src/websocket_caller_transport.dart]
probe: none — static read, nothing run
reason: "bench — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); the auditing container had no Dart SDK, so nothing here was run and the witness below is unbuilt"
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
