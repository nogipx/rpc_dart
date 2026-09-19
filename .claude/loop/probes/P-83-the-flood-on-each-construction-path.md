---
file: packages/transport/rpc_dart_http2/.dart_tool/probe/guard_on_the_direct_path.dart
round: 394
commit: 2489ffde
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_responder_transport.dart, packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_server.dart, packages/transport/rpc_dart_http2/lib/src/transports/http2/http2_header_block_guard.dart]
status: valid
---

# P-83 — the same flood, one construction path apart

## Why it exists

`guardHttp2HeaderBlock` was applied in `RpcHttp2Server`. But
`RpcHttp2ResponderTransport` is exported and takes an already-built
`ServerTransportConnection`, so a user with their own accept loop — TLS, ALPN, a
shared port — never gets it. The policy object they pass reads as if they did.

## Measures

How many CONTINUATION frames the server takes before it stops reading, driven by
a peer that opens a header block and never ends it: 4096 frames of 16 KiB, 64
MiB in all.

Three arms, the same policy and the same flood in each:

- `server` — `RpcHttp2Server`, the guarded path, and the CONTROL
- `direct` — a hand-rolled accept loop with the raw `connection:` constructor
- `direct via overStreams` — the same loop through the guarded factory

## Control

The server arm. Identical flood, identical policy, differing only in how the
connection was built, so a difference between them is the construction path and
nothing else.

## The number is FRAMES, not RSS

RSS was measured too and is **not** the evidence: across runs the unguarded arm
read +178 MiB and +27 MiB for identical input, because the reading depends on
where the GC happens to be. The frame count is deterministic — 65 against 4096 —
and it is what the witness asserts. Recorded because the RSS figure is the more
quotable one and would have been the wrong thing to quote.

## The numbers (round 394)

```
arm                             frames accepted
server (RpcHttp2Server)            65 of 4096
direct (own accept loop, raw)    4096 of 4096
direct via overStreams             65 of 4096
```

## What it establishes, and what it does not

Establishes: the CONTINUATION-flood guard was absent from an exported
construction path, and `overStreams` gives that path the server's behaviour
exactly.

Does not cover the OTHER thing the same construction block applies — the
advertised `SETTINGS_MAX_CONCURRENT_STREAMS` — which was fixed alongside it on
the strength of reading, not of a measurement. A bench for that would have to
read the peer's SETTINGS frame.
