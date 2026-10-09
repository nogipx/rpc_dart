---
round: 772
verdict: CLEAN
packages: [rpc_dart, rpc_dart_websocket, rpc_dart_http2, rpc_dart_http, rpc_dart_isolate]
lens: RPC-08
bench: P-272 — new
commit: yes
release: none
---

# Round 772 — over the limit across the transports

## Target

After rounds 768-770 made messages up to the limit work everywhere: a
message just over `maxMessageLengthBytes`, both directions, every
transport. Does each refuse the call with RESOURCE_EXHAUSTED, and does the
connection survive?

## Hypothesis

Some transport hangs, answers with the wrong status, or loses the
connection for a refusal that should cost one call.

## Before

P-272, 64 KiB limit, 70000-byte message:

```
  websocket  unary big request: status 8    then: status 14
             (the other three rows: 14, then 14 -- the connection is gone)
  http2      all four rows: status 8        then: ok
  http       all four rows: status 8        then: ok
  isolate    all four rows: ok (70000 chars) then: ok
  core pair  big request: status 14 (server closes on an oversized client frame)
  core framed channel: status 8 both ways
```

## Mechanism

Three answers, each by design:

- websocket: the frame guard closes the connection before reading an
  oversized message, so nothing is buffered; the owner chose that in B-251
  (round 680), with a dedicated close code read as RESOURCE_EXHAUSTED.
- core pair: `RpcChannelTransport.fromChannel` sets
  `closeOnOversizedFrame: !isClient`, the same choice for an untrusted
  client on a byte stream.
- isolate: no frame layer, so no limit; C-67.

## After

n/a.

## Canary

n/a: no fix. The http2 and http rows are the control that the bench sees
a refusal.

## The verdict questions

1. The rows differ in transport and direction only.
2. Yes: refusals (8), lost connections (14) and passes (ok) all show.
3. At the caller.
4. n/a.
5. n/a.
6. n/a.
7. CLEAN: every outcome is a documented choice (B-251, `fromChannel`,
   C-67), and none hangs or misreports.
8. websocket's lost connection ruled by B-251's owner decision, read in
   round 680; isolate's pass ruled by its trust model, written into C-67.
9. None.
A1. One policy on both ends.
A2. Volume.
L1. Each refusal named the message limit.

## Gate

n/a — no code change.

## Not fixed

Nothing.

## Links

Probe `../probes/P-272-a-message-just-over-the-limit-on-every-transport.md`.
Negative `../checked/C-67-the-message-limit-is-the-frame-layers.md`.
Round `680-an-oversized-websocket-request-says-so.md`.
