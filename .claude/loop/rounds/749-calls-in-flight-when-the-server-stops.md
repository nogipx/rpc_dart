---
round: 749
verdict: CLEAN
packages: [rpc_dart_websocket, rpc_dart_http2, rpc_dart]
lens: RPC-08
bench: P-253 — new
commit: yes
release: none
---

# Round 749 — calls in flight when the server stops

## Target

Round 746 gave `RpcClientConnection` a new way to retire a transport, on
`connectionLost`. The READMEs say calls in flight during a drop are lost. Do
they fail promptly with a retryable status, or wait out a deadline, on both
network transports, bare and behind the connection?

## Hypothesis

A call in flight hangs, or ends without a status, on one of the four paths.

## Before

P-253, the server stopped once the stream's first item arrived:

```
  websocket bare  server stream status 14 at 17 ms   unary status 14 at 16 ms
  websocket conn  server stream status 14 at 23 ms   unary status 14 at 22 ms
  http2     bare  server stream status 14 at 17 ms   unary status 14 at 16 ms
  http2     conn  server stream status 14 at 20 ms   unary status 14 at 18 ms
```

## Mechanism

None. Every path ends both calls with UNAVAILABLE within tens of ms, the
status the retry interceptor and the reconnecting connection act on.

## After

n/a.

## Canary

n/a — no fix. The control is the stream's first item: each call was live when
the server stopped.

## The verdict questions

1. Yes: a graceful `stop()` of the shipped servers.
2. Yes: four paths, the same reading on each.
3. At the caller.
4. n/a.
5. n/a.
6. n/a.
7. CLEAN.
8. None.
A1. A graceful server stop. A server that vanishes without closing its
sockets is keepalive's case, not this round's.
A2. Latency to a failure.
L1. n/a.

## Gate

No library change.

## Not fixed

Nothing.

## Links

Lens `../lenses/RPC-08-policy-field-single-transport.md` — `applied: [..., 749]`.
New bench `../probes/P-253-calls-in-flight-when-the-server-stops.md`.
