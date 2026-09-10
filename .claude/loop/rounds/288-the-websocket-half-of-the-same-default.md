---
round: 288
verdict: FIXED
packages: [rpc_dart_websocket]
lens: RPC-22
bench: P-35 — new
commit: yes
---

# Round 288 — the websocket half of the same default

## Target

The item round 287 named and did not change. The owner asked why websocket needs
`pingInterval` at all, I answered by quoting the numbers in the function's OWN
DOC COMMENT, and was told — correctly — that documentation is never evidence.
So this round exists because a claim was made without a measurement.

## Hypothesis

A peer that COMPLETES the websocket upgrade and then goes silent holds its
endpoint, and the contracts on it, with nothing to reclaim it. Round 274 covered
the stage before this one (200 silent TCP sockets give 0 endpoints, because the
endpoint is built only for an upgraded connection); this is the stage after.

## Before

20 peers that finish the handshake on a raw socket and then never speak
websocket again, so they answer no PING — which is what a NAT box or a mobile
network that stopped forwarding looks like from the server's side.

```
arm  pingInterval  endpoints held  contracts built  contracts disposed
off  null                      20               20                   0
on   300ms                      0               20                  20
```

Probe: `packages/transport/rpc_dart_websocket/.dart_tool/probe/upgraded_then_silent.dart`

`HttpServer.idleTimeout` reads 2 minutes in both arms and reclaims nothing: it
governs idle HTTP connections between requests, and an upgraded socket has left
that management. Measured rather than assumed, since that was the whole
complaint.

## Mechanism

Same as http2's second stage. `pingInterval` is set on the dart:io `WebSocket`
between the upgrade and the wrap — the only seam where it is reachable, because
`IOWebSocketChannel` hides the socket — and without it nothing ever asks the
peer whether it is alive.

## After

`pingInterval` defaults to 30s. The `off` arm re-run with the new default in
place still reads 20/0, because it passes `null` explicitly; that is the
ablation.

## Canary

The mechanism was already pinned by three tests
(`server_keepalive_reclaims_dead_test`, `keepalive_detects_half_open_test`,
`server_reclaims_via_public_api_test`), all passing an explicit interval, and
all still green. **The DEFAULT is pinned by the probe's `off` arm and not by a
fast unit test**, exactly as in round 287 — a 30s default cannot be witnessed
inside a unit suite's budget. Stated here rather than papered over.

## Gate

`melos run analyze` (21 packages + wasm), `melos run test:unit --no-select`,
`melos run format:check`, `melos run license:check` — all green.
`rpc_dart_websocket` alone: 137 tests.

## Not fixed

Nothing outstanding for this default.

**The round also cut the file's doc comment from ~150 lines to ~40**, on the
owner's objection, and that is the second rule this round broke before being
corrected: `config.md` says the search narrative goes into the commit and the
journal, not beside the code. What was there had four measured tables, three
code samples and a paragraph on the Fetch standard. What survives is the
number, the trade, and the default — the rest is in the journal, which is where
a reader who wants it should have to go.

## Links

RPC-22 (`applied:` gains 288). Bench P-35, new. Round 287 is the http2 half;
B-27 was already closed by it and stays closed.
