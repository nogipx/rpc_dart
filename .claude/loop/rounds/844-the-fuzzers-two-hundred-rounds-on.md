---
round: 844
verdict: CLEAN
packages: [rpc_dart, rpc_dart_websocket]
lens: RPC-13
bench: P-225 — reused
commit: yes
release: none
---

# Round 844 — the fuzzers, two hundred rounds on

## Target

Network-audit method §4, levels 1 and 2. P-225's harnesses were last run at
scale in round 639; since then the frame channel, the parser's in-place
decode, the flow controller, the websocket frame guard and its header bound,
and this session's `ownedPayload` copies have all changed. The gate runs
fixed-seed slices of them, so a seed is the same inputs every time. RPC-13
(an error that reaches the zone) is the harnesses' main oracle.

## Hypothesis

A peer's bytes crash, hang or wedge an rpc_dart process, or a decoder
throws an `Error` where it should refuse with a typed exception, on inputs
the gate's seeds never produce.

## Before

```
harness (seed)                       volume                 result
fuzz_decoders (8401)                 30 000 x 11 targets    typed refusals only: FormatException,
                                                            RpcFrameException, RpcStatusException,
                                                            RpcPeerFaultException; no Error, none slow
fuzz_server (8402)                   2000 sessions          ok 2000, uncaught 0
fuzz_client (8403)                   800 sessions           ok 800, uncaught 0
fuzz_peer (8404)                     800 sessions           ok 800, uncaught 0
fuzz_ws_server, compression off      1000 attacks           100 of 100 checks served, uncaught 0
fuzz_ws_server, compression on       500 attacks            50 of 50 checks served, uncaught 0
fuzz_ws_client (8407)                400 sessions           ok 400, uncaught 0
```

The control is each harness's well-formed path, run inside every session:
the seeds decode, the valid call is answered, the clean client is served.

## Mechanism

None found.

## After

n/a — nothing to fix.

## Canary

n/a — no fix.

## Gate

No library change.

## Siblings

—

## Not fixed

Nothing found. P-225 has no http or http2 harness; those transports were not
fuzzed here.

## Links

Lens `../lenses/RPC-13-unhandled-async-error.md`. Bench
`../probes/P-225-what-a-fuzzer-finds-in-the-decoders-and-the-servers.md`.
Negative `../checked/C-83-the-fuzzers-two-hundred-rounds-on.md`.
