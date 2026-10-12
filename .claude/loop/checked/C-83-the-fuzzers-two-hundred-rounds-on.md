---
round: 844
commit: 14bda878
paths: [packages/core/rpc_dart/lib/src/codec/**, packages/core/rpc_dart/lib/src/core/**, packages/core/rpc_dart/lib/src/rpc/transports/**, packages/core/rpc_dart/lib/src/endpoint/**, packages/transport/rpc_dart_websocket/lib/**]
scope: P-225's six harnesses with seeds 8401-8407; core decoders, server, client and peer over a fake channel; the websocket server (compression off and on) and client over real sockets; not http or http2
---

# C-83 — the fuzzers, two hundred rounds on

P-225's harnesses, last run at scale in round 639, found nothing at
seeds 8401-8407: 30 000 inputs into each of 11 decoders refused only with
typed exceptions; 2000 server, 800 client, 800 peer and 400 websocket-client
sessions with nothing in the zone and every valid call answered; 1500
websocket-server attacks with every clean client served.

Run them again with a NEW seed: the gate's slices use fixed ones, so a re-run
at the old seed repeats the same inputs.

## Control

Each harness's well-formed path, inside every session: seeds decode, the
valid call is answered, the clean client is served.
