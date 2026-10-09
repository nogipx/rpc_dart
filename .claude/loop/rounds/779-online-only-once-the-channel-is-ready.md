---
round: 779
verdict: FIXED
packages: [rpc_dart, rpc_dart_websocket]
lens: RPC-19
bench: P-258 — reused
commit: yes
release: changelog
severity: S2
---

# Round 779 — online only once the channel is ready

## Target

B-268, by the owner's decision (2026-10-09): a readiness capability in
core. `RpcWebSocketCallerTransport(channel)` over a channel still
connecting read healthy at once, and `RpcClientConnection` reported Online
when its factory returned such a transport: one word, Online, meaning both
"a transport exists" and "calls can go".

## Hypothesis

With the connection waiting on the transport's readiness, a channel that
never connects is never Online, and one that connects still is.

## Before

P-258 (`r753_online_before_ready.dart`), no server, `maxAttempts: 4`:

```
  ctor   Online emitted 4   each Online -> Offline within ~2-5 ms
  ready  Online emitted 0   (the factory awaits channel.ready itself)
```

## Mechanism

Core gains `IRpcTransportReadiness` (`Future<void> get ready`).
`RpcClientConnection` awaits it after the factory returns and before
Online, within what is left of the attempt's `connectTimeout`; a failure
or a timeout closes the transport and fails the attempt like a factory
that threw. `RpcWebSocketCallerTransport` implements it with the current
socket's `ready`, re-armed on every reconnect, and `health()` reads
degraded until it completes.

## After

```
  ctor   Online emitted 0   factory calls 4   final Disconnected (765 ms)
  ready  Online emitted 0   factory calls 4   final Disconnected
```

## Canary

`packages/transport/rpc_dart_websocket/test/a_channel_that_never_connects_never_reads_online_test.dart`,
3 of 3 green. With `client_connection.dart` reverted: `Online was reported
for a channel that never connected`, and the connected arm's health reads
degraded, since Online then precedes the handshake.

## The verdict questions

1. The arms differ in whether the factory awaits `ready` itself.
2. Yes: 4 Online against 0 before; 0 and 0 after.
3. The connection's own state stream.
4. 0 Online with 4 attempts made: the attempts happened.
5. Yes, above.
6. Two halves (core wait, websocket capability); the canary reverted the
   core half, and without the websocket half there is no `ready` to wait
   on, so the witness also fails.
7. FIXED.
8. Nothing dismissed. A one-off 1.7 s gap between attempts in the first
   after-run was the host's ENETDOWN, gone on the traced re-run.
9. None.
A1. n/a.
A2. Latency (a channel still connecting), from a real closed port.
L1. n/a.

## Gate

`melos run analyze`, `format:check`, `check:skills`, `test:unit`,
`test:web` green. The websocket README and the skill's resilience
reference describe the readiness wait.

## Not fixed

Nothing here. The claim first written here, that the other caller
transports need no `ready`, was not measured; round 780 measured http2 and
it did.

## Links

Lead `../backlog/B-268-a-constructed-websocket-transport-reports-online-early.md`.
Bench `../probes/P-258-online-before-the-handshake.md`.
