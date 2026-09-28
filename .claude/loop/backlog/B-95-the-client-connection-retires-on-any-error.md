---
status: open
round: — (external audit, 2026-09-28; not a round)
commit: 8253fe8a
paths: [packages/core/rpc_dart/lib/src/resilience/client_connection.dart, packages/core/rpc_dart/lib/src/rpc/transports/channel_transport.dart, packages/transport/rpc_dart_websocket/lib/src/websocket_caller_transport.dart]
probe: none — static read, nothing run
reason: "bench — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); the auditing container had no Dart SDK, so nothing here was run and the witness below is unbuilt"
---

# B-95 — RpcClientConnection treats every error on incomingMessages as a dropped connection

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**high**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

The proxy listens with `cancelOnError: true` and `onError → _retire(inner)`; the channel transport forwards ADVISORY errors (a proxy's text frame) and lenient-mode policy violations into that stream, so a non-fatal observation closes and reconnects the connection.

## The shape

`packages/core/rpc_dart/lib/src/resilience/client_connection.dart:180-197`:

```dart
_innerSub = inner.incomingMessages.listen(
  (msg) { ... },
  onDone: () { ...; _retire(inner); onDropped?.call(null); },
  onError: (Object e) {
    if (!identical(_inner, inner)) return;
    _retire(inner);
    onDropped?.call(e);
  },
  cancelOnError: true,
);
```

Non-fatal errors that reach that stream:

- `channel_transport.dart:181-186` skips per-stream controllers for an
  `IRpcAdvisoryChannelError` but still does `_incoming.addError(e)`;
- `channel_transport.dart:729-731` adds an `RpcFrameException.policy` for a lenient
  (`closeOnProtocolError: false`) violation and keeps the connection;
- `websocket_caller_transport.dart:344-346` forwards both unchanged.

## Why it matters

The advisory contract (`errors.dart:61`, `responder_pipeline.dart:428`) says the
connection still works. Behind `RpcClientConnection` it is torn down and
reconnected, failing every call in flight. A proxy that sends a text keepalive
therefore makes the reconnecting client flap on every keepalive.

## Witness a round would build

`RpcClientConnection` over a websocket factory; the server side writes one text
frame to the socket while a call is in flight. Count reconnects and the call's
outcome. Guard arm: the same without the text frame.

## Fix sketch

Retire only on `onDone`, or on an error the transport declares fatal; skip
`IRpcAdvisoryChannelError` and `RpcFrameException.policy`; drop
`cancelOnError: true`.

## Owner decision

—
