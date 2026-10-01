---
round: 598
verdict: FIXED
packages: [rpc_dart_websocket]
lens: RPC-17
bench: none — the cap is a count of connections, read and asserted directly by the test; a bench would measure the same integer
budget: probes 0/5, canaries 0/5
commit: yes
release: changelog
---

# Round 598 — the connection nothing refused

## Target

B-139 item 6d, which the owner asked to implement in round 597's session:
`RpcWebSocketServer` had no ceiling on concurrent connections. No server in the repo
has one (http, http2, websocket alike), so this is the first.

## Hypothesis

Every accepted socket builds an endpoint and a transport with their buffers, and
nothing refuses the next one, so with `maxConnections: 2` a third client is served.

## Before

The cap witness, with the check switched off in place:
`Expected: not 'x', Actual: 'x' — a third connection was served past
maxConnections: 2`.

## Mechanism

`_handleConnection` admits every channel the `connections` stream yields while the
server is running; the only refusal was the stopped-server one.

## After

- `maxConnections` (default null, no cap), also on `createWithContracts`.
- Counted on the live endpoint list, which a closed connection leaves on its
  `sink.done`, so a slot comes back.
- Over the cap the socket is closed with 1000 and a reason, the way the
  stopped-server refusal already does it (package:web_socket will not send the
  reserved codes). The refused caller sees `RpcStatusException(14)` — UNAVAILABLE,
  retryable.
- The refusal warns once per stretch at the limit, re-armed when a slot frees.

## Canary

1. The cap check off: `Expected: not 'x', Actual: 'x'`.
2. The wrong neighbour — counting connections EVER opened instead of live ones:
   the refusal still holds and the release fails, `Expected: 'x', Actual:
   'RpcStatusException(14): The stream closed before the peer sent a status' — a
   closed connection did not free its slot`.
3. The warn-once guard off: `Expected: an object with length of <1> ... has length
   of <5> — 5 warnings`.

## Gate

`melos run analyze`, `melos run test:unit --no-select` (15 packages,
rpc_dart_websocket +248, rpc_dart +1892), `melos run format:check`, `melos run
license:check` — green.

## Not fixed

The http and http2 servers still have no connection cap; nothing asked for one and
both sit behind a listener the application owns.

## Links

Lead `../backlog/B-139-websocket-cleanup-items.md` — open, item 4 left.
Lens `../lenses/RPC-17-limit-fires-after-residency.md` — `applied: [598]`.
Test `packages/transport/rpc_dart_websocket/test/the_server_caps_its_connections_test.dart`.
