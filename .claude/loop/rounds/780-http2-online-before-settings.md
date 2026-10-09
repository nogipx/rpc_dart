---
round: 780
verdict: FIXED
packages: [rpc_dart_http2]
lens: RPC-19
bench: P-275 — new
commit: yes
release: changelog
---

# Round 780 — http2 online before settings

## Target

The owner asked whether readiness (round 779) is needed by the websocket
transport only. Round 779's record said the other caller transports
"return only once connected"; that was read, not measured. http2's
`connect()` returns once the socket is up, and the peer's SETTINGS (the
proof it speaks HTTP/2) arrive later; round 754 only bounds how long that
may take. `viaSocket` is a synchronous constructor over a raw socket.

## Hypothesis

`RpcClientConnection` reports Online, with `health()` healthy, for an
http2 transport whose peer never sends SETTINGS.

## Before

P-275, a peer that accepts and stays silent:

```
  connect    Connecting@2ms -> Online@26ms   health healthy
  viasocket  Connecting@2ms -> Online@24ms   health healthy
```

The connection would only learn otherwise 30 s later, when round 754's
SETTINGS timer destroys the socket.

## Mechanism

`RpcHttp2CallerTransport` now implements `IRpcTransportReadiness`: `ready`
completes on the current connection's `onInitialPeerSettingsReceived`,
fails when that connection is lost first, and is re-armed on every
`reconnect()`. `health()` reads degraded until it completes.

## After

```
  connect    Connecting@2ms   health unhealthy (no Online)
  viasocket  Connecting@2ms   health unhealthy (no Online)
```

## Canary

`packages/transport/rpc_dart_http2/test/a_peer_without_settings_is_never_online_test.dart`,
3 of 3 green; with the transport reverted: `Actual: <Instance of
'RpcClientOnline'>`. The second test (a real server reads Online and
healthy) passes in both.

## The verdict questions

1. The arms differ in how the transport is built; both are fixed.
2. Yes: Online at ~25 ms against none.
3. The connection's state stream and the transport's own health.
4. 5 s watched; the bounded attempt ends at 2 s in the witness.
5. Yes, above.
6. One half (core's wait is round 779).
7. FIXED.
8. Round 779's "other transports need no ready" was a record and is now
   measured: http2 needed it. http (HTTP/1.1) has no connection to be
   ready; isolate's `spawn` already awaits its own ready message.
9. A "the others don't need it" written while fixing one transport is a
   parity claim; measure it on each before writing it. Price: one round.
A1. n/a.
A2. Latency (a silent peer), from a real socket.
L1. n/a.

## Gate

`melos run analyze`, `format:check`, `check:skills`, `test:unit` green on
the second run. The first run had one red,
`graceful_drain_on_stop_test` "a drained stop lets an in-flight call
finish" (`status 14`), green in 3 full http2 runs and 11 isolated ones
(6 in parallel). The test stopped the server 300 ms after firing the call,
assuming the call had reached the handler; under the workspace gate's load
it may not have. It now waits for the handler to signal entry (L-19: the
variable named, removed from the test).

## Not fixed

Nothing.

## Links

Probe `../probes/P-275-online-before-an-http2-peer-has-spoken.md`.
Round `779-online-only-once-the-channel-is-ready.md`.
