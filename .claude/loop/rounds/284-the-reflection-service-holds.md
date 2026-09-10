---
round: 284
verdict: CLEAN
packages: [rpc_dart_grpc_reflection]
lens: RPC-22
bench: P-33 — new
commit: yes
---

# Round 284 — the reflection service holds

## Target

`rpc_dart_grpc_reflection`, found by correcting my own claim that core and
transport had nothing unmeasured left. A grep put it and `rpc_dart_compression`
in exactly ONE round file between them — 219, and only as a gate census.

It is the sharpest of the two: a service that answers UNAUTHENTICATED peers,
enumerates every registered service and method, and decodes the peer's protobuf
by hand. RPC-22's question — what does a peer reach without being accepted —
answers itself here, because reflection accepts everyone by design.

## Hypothesis

The hand-rolled decoder produces an `Error` on some input. The receive loop
catches `Exception`, so an `Error` escaping reaches the zone, and on a server
that is a process kill from one request. Round 278 asked exactly this of the
frame codec; this is the other hand-rolled parser in the repository.

## Before

Seventeen malformed requests through `processRequestForTest`.

```
CONTROL  well-formed list_services            answered 5 bytes

empty                                         answered      26
a lone continuation byte                      answered      26
varint with 12 continuation bytes             answered      38
varint of all 0xFF (never terminates)         answered      89
length declares more than is present          answered      50
length 0x7FFFFFFF                             answered      53
truncated 64-bit field                        answered      52
truncated 32-bit field                        answered      51
wire type 6 (reserved)                        answered      52
wire type 7 (reserved)                        answered      52
field 0 (illegal)                             answered      30
invalid UTF-8 in file_by_filename             answered      30
invalid UTF-8 in symbol                       answered      30
a 1 MiB symbol name                           answered 1048629
symbol full of NUL                            answered     156
list_services set                             answered       5
every field at once                           answered      19
```

Probe: `packages/core/rpc_dart_grpc_reflection/.dart_tool/probe/hostile_reflection_requests.dart`

**Zero leaked Errors, zero leaked Exceptions.** Every case becomes a gRPC error
response.

## Mechanism

n/a — nothing is broken, and two things are load-bearing in why.

`_processRequest`'s `catch (_)` is deliberately un-typed, and that is what
holds: a bare `on Exception` would let an `Error` through. And `_readVarint` is
bounded twice — `pos < bytes.length` plus a `shift >= 64` throw — so the
all-0xFF case terminates instead of spinning.

## After

n/a.

## Canary

n/a. The control is a well-formed `list_services` through the identical call,
answered in 5 bytes, so every refusal is attributable to the content.

## Gate

n/a — no code changed. `loop.py lint` green.

## Not fixed

Two things recorded in C-33 rather than pursued.

**The echo, which only the SIZE column shows.** A 1 MiB symbol name comes back
as a 1 MiB response, because the reflection proto requires `original_request` in
every reply. That is 1:1, and RPC-17's rule is that a bomb is defined by
amplification rather than absolute size — the attacker sends every byte it wants
back, and the inbound side is bounded by `maxMessageLengthBytes`. A bench
printing `ok` per case would have shown seventeen clean rows and missed it
entirely.

**The recursive descriptor parser, deliberately out of scope.**
`_collectAllTypeNames` recurses on `nested_type` with no depth limit and a
`StackOverflowError` is an `Error` — but its only caller is
`RpcReflectionRegistry.addFileDescriptor`, which takes bytes the DEVELOPER
generated. Not peer-reachable, so it is a robustness question about generator
output rather than an attack surface. Checking reachability before building the
bench is what kept this round to the decoder.

`rpc_dart_compression` remains unmeasured; its gzip-bomb half is already covered
by C-17 (rounds 76, 107, 108).

## Links

RPC-22 (`applied:` gains 284) — its first application outside the transports.
Bench P-33, new, and P-28's shape aimed at the other hand-rolled parser.
Negative C-33.
