---
status: closed (round 691)
round: 691
commit: 8253fe8a
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart]
probe: none — static read, nothing run
reason: "bench — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); the auditing container had no Dart SDK, so nothing here was run and the witness below is unbuilt"
---

# B-179 — http2 caller: keepalive death yields FAILED_PRECONDITION, and a late probe can mark a new connection dead

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**medium**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

`onDead` sets `_disconnected = true`; with no reconnect in flight `_ensureUsable` throws `RpcNoConnectionException(reconnecting: false)` (not retried), while the same dead peer without keepalive yields UNAVAILABLE from `sendMetadata`; `onDead` never checks `identical(connection, _connection)`, so a probe that times out after `reconnect()` marks the healthy transport disconnected.

## The shape

`packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart:276-284, 870-874`.

## Why it matters

Retry semantics depend on how the death was detected; a race can take down a
fresh connection.

## Witness a round would build

Keepalive 200 ms; pause the server; reconnect as the probe times out.

## Fix sketch

Guard on identity; pick one status for "peer gone".

## Outcome (round 691)

CLEAN, both claims. A call after a keepalive death is UNAVAILABLE (round 678
unified the status); a probe that times out after `reconnect()` leaves the new
connection working. Both checks kept as tests.
`../rounds/691-keepalive-death-is-unavailable.md`.

## Owner decision

—
